"""
Cloud Run Job: ingest a survey drop from GCS into canon_* tables.

Env:
  GCP_PROJECT      default archetypeid-staging
  STUDY_ID         e.g. drop-002
  FORMAT_ID        e.g. abr_persona_v1
  GCS_PREFIX       e.g. gs://archetypeid-staging-surveys/drop-002/
  CANON_RESPONDENT archetypeid-staging.svy.canon_respondent
  CANON_RESPONSE   archetypeid-staging.svy.canon_response
"""

from __future__ import annotations

import io
import os
import re
from typing import Any
from urllib.parse import urlparse

import pandas as pd
from google.cloud import bigquery, storage

PROJECT = os.environ.get("GCP_PROJECT", "archetypeid-staging")
STUDY_ID = os.environ["STUDY_ID"]
FORMAT_ID = os.environ["FORMAT_ID"]
GCS_PREFIX = os.environ["GCS_PREFIX"].rstrip("/") + "/"
CANON_RESPONDENT = os.environ.get(
    "CANON_RESPONDENT", f"{PROJECT}.svy.canon_respondent"
)
CANON_RESPONSE = os.environ.get(
    "CANON_RESPONSE", f"{PROJECT}.svy.canon_response"
)


def _parse_gcs_uri(uri: str) -> tuple[str, str]:
    # gs://bucket/path/
    p = urlparse(uri)
    return p.netloc, p.path.lstrip("/")


def detect_arm(filename: str) -> str:
    if re.search(r"-K3-", filename):
        return "K3"
    if re.search(r"-K9-", filename):
        return "K9"
    if re.search(r"-HTR-", filename):
        return "HTR"
    m = re.search(r"-FF-([GS])-", filename)
    if m:
        return m.group(1)
    return "UNKNOWN"


def tabulation_kind(type_code: Any, rating: Any, selected: Any) -> str:
    t = str(type_code).strip() if type_code is not None and not (isinstance(type_code, float) and pd.isna(type_code)) else ""
    if t in {"4", "5"}:
        return "SELECT"
    if t == "1":
        return "OTHER"
    if rating is not None and str(rating).strip() not in {"", "nan"}:
        return "SCALE"
    if selected is not None and str(selected).strip() not in {"", "nan"}:
        return "SELECT"
    return "OTHER"


def option_value(kind: str, selected: Any, rating: Any, qual: Any) -> str | None:
    def clean(v: Any) -> str | None:
        if v is None or (isinstance(v, float) and pd.isna(v)):
            return None
        s = str(v).strip()
        return s or None

    if kind == "SELECT":
        return clean(selected)
    if kind == "SCALE":
        return clean(rating) or clean(selected)
    if kind == "OTHER":
        return clean(qual) or clean(selected)
    return clean(selected) or clean(qual) or clean(rating)


def list_csv_blobs(gcs: storage.Client, prefix_uri: str) -> list[storage.Blob]:
    bucket_name, prefix = _parse_gcs_uri(prefix_uri)
    bucket = gcs.bucket(bucket_name)
    blobs = [
        b
        for b in bucket.list_blobs(prefix=prefix)
        if b.name.lower().endswith(".csv") and not b.name.endswith("/")
    ]
    if not blobs:
        raise RuntimeError(f"No CSV files under {prefix_uri}")
    return blobs


def read_csv_blob(gcs: storage.Client, blob: storage.Blob) -> pd.DataFrame:
    data = blob.download_as_bytes()
    return pd.read_csv(io.BytesIO(data), dtype=str, keep_default_na=False)


def unpivot_abr(df: pd.DataFrame, source_file: str, sample_arm: str) -> tuple[pd.DataFrame, pd.DataFrame]:
    if "archetype_id" not in df.columns:
        raise RuntimeError(f"{source_file}: missing archetype_id")

    respondents = pd.DataFrame(
        {
            "study_id": STUDY_ID,
            "respondent_id": df["archetype_id"].astype(str),
            "format_id": FORMAT_ID,
            "gender": df.get("archetype_gender", pd.Series([None] * len(df)))
            .astype(str)
            .str.strip()
            .str.title()
            .replace({"": None, "Nan": None}),
            "age_band": df.get("archetype_age_range", pd.Series([None] * len(df)))
            .astype(str)
            .str.strip()
            .replace({"": None, "Nan": None}),
            "sample_arm": sample_arm,
            "source_file": source_file,
        }
    ).drop_duplicates(subset=["study_id", "respondent_id", "source_file"])

    q_nums = sorted(
        {
            int(m.group(1))
            for c in df.columns
            if (m := re.match(r"^Q(\d+)_question$", c))
        }
    )
    rows: list[dict[str, Any]] = []
    for _, rec in df.iterrows():
        rid = str(rec["archetype_id"])
        for n in q_nums:
            q = f"Q{n}"
            q_text = rec.get(f"{q}_question", "")
            if not str(q_text).strip():
                continue
            tcode = rec.get(f"{q}_type")
            rating = rec.get(f"{q}_rating")
            selected = rec.get(f"{q}_selected")
            qual = rec.get(f"{q}_qual")
            kind = tabulation_kind(tcode, rating, selected)
            oval = option_value(kind, selected, rating, qual)
            rating_f = None
            try:
                if rating is not None and str(rating).strip() not in {"", "nan"}:
                    rating_f = float(rating)
            except ValueError:
                rating_f = None
            rows.append(
                {
                    "study_id": STUDY_ID,
                    "respondent_id": rid,
                    "format_id": FORMAT_ID,
                    "question_code": q,
                    "question_text": str(q_text).strip(),
                    "tabulation_kind": kind,
                    "option_value": oval,
                    "rating": rating_f,
                    "source_file": source_file,
                }
            )

    responses = pd.DataFrame(rows)
    return respondents, responses


def replace_study_canon(bq: bigquery.Client, respondents: pd.DataFrame, responses: pd.DataFrame) -> None:
    bq.query(
        f"DELETE FROM `{CANON_RESPONDENT}` WHERE study_id = @study_id",
        job_config=bigquery.QueryJobConfig(
            query_parameters=[bigquery.ScalarQueryParameter("study_id", "STRING", STUDY_ID)]
        ),
    ).result()
    bq.query(
        f"DELETE FROM `{CANON_RESPONSE}` WHERE study_id = @study_id",
        job_config=bigquery.QueryJobConfig(
            query_parameters=[bigquery.ScalarQueryParameter("study_id", "STRING", STUDY_ID)]
        ),
    ).result()

    job_config = bigquery.LoadJobConfig(write_disposition="WRITE_APPEND")
    bq.load_table_from_dataframe(respondents, CANON_RESPONDENT, job_config=job_config).result()
    bq.load_table_from_dataframe(responses, CANON_RESPONSE, job_config=job_config).result()


def upsert_study_registry(bq: bigquery.Client) -> None:
    """Update status/uri if row exists; otherwise insert required columns only."""
    bq.query(
        """
        UPDATE `archetypeid-staging.svy_config.study_registry`
        SET
          format_id = @format_id,
          gcs_uri = @gcs_uri,
          gcs_prefix = @gcs_prefix,
          status = 'loaded'
        WHERE study_id = @study_id
        """,
        job_config=bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("study_id", "STRING", STUDY_ID),
                bigquery.ScalarQueryParameter("format_id", "STRING", FORMAT_ID),
                bigquery.ScalarQueryParameter("gcs_uri", "STRING", GCS_PREFIX),
                bigquery.ScalarQueryParameter("gcs_prefix", "STRING", GCS_PREFIX),
            ]
        ),
    ).result()

    # If no row was updated, insert a new one (gcs_uri is required on this table)
    bq.query(
        """
        INSERT INTO `archetypeid-staging.svy_config.study_registry`
          (study_id, format_id, gcs_uri, gcs_prefix, status, created_at, notes)
        SELECT
          @study_id, @format_id, @gcs_uri, @gcs_prefix, 'loaded', CURRENT_TIMESTAMP(),
          'Ingested by Cloud Run job survey-drop-ingest'
        FROM (SELECT 1)
        WHERE NOT EXISTS (
          SELECT 1 FROM `archetypeid-staging.svy_config.study_registry`
          WHERE study_id = @study_id
        )
        """,
        job_config=bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("study_id", "STRING", STUDY_ID),
                bigquery.ScalarQueryParameter("format_id", "STRING", FORMAT_ID),
                bigquery.ScalarQueryParameter("gcs_uri", "STRING", GCS_PREFIX),
                bigquery.ScalarQueryParameter("gcs_prefix", "STRING", GCS_PREFIX),
            ]
        ),
    ).result()

def ingest_abr(gcs: storage.Client, bq: bigquery.Client) -> None:
    blobs = list_csv_blobs(gcs, GCS_PREFIX)
    all_resp = []
    all_ans = []
    for blob in blobs:
        filename = blob.name.split("/")[-1]
        arm = detect_arm(filename)
        print(f"Reading gs://{blob.bucket.name}/{blob.name} arm={arm}")
        df = read_csv_blob(gcs, blob)
        resp, ans = unpivot_abr(df, filename, arm)
        print(f"  people={len(resp)} answer_rows={len(ans)}")
        all_resp.append(resp)
        all_ans.append(ans)

    respondents = pd.concat(all_resp, ignore_index=True)
    responses = pd.concat(all_ans, ignore_index=True)
    print(f"TOTAL people={len(respondents)} answers={len(responses)}")
    replace_study_canon(bq, respondents, responses)
    upsert_study_registry(bq)
    print("canon_* + study_registry updated")


def main() -> None:
    print(f"STUDY_ID={STUDY_ID} FORMAT_ID={FORMAT_ID} GCS_PREFIX={GCS_PREFIX}")
    gcs = storage.Client(project=PROJECT)
    bq = bigquery.Client(project=PROJECT)

    if FORMAT_ID == "abr_persona_v1":
        ingest_abr(gcs, bq)
    else:
        raise RuntimeError(
            f"FORMAT_ID={FORMAT_ID} not supported in this job yet. "
            "Add an adapter (arena_ff_v1 next) or run the FF path separately."
        )


if __name__ == "__main__":
    main()
