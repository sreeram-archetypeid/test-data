# ABR pipeline handoff — Sreeram vs Rishi (no overlap)

Goal: both can work the **same repo** without editing the same files or fighting Dataform/BQ writes.

## Hard rule

| Owner | May touch | Must not touch |
|---|---|---|
| **Sreeram** | `pipeline/dataform/banners/**`, `pipeline/dataform/config/abr_box_defs.sql`, BQ exports / Sheets QA | `pipeline/dataform/definitions/**`, `pipeline/cloud_run_job/**`, Dataform UI models, `int_cut_attrs` / `stg_clean` / `mart_stubs` |
| **Rishi** | `pipeline/dataform/definitions/**`, `pipeline/cloud_run_job/**`, `pipeline/dataform/adapters/**`, Dataform UI sync, IAM/Cloud Run | `pipeline/dataform/banners/**`, `pipeline/dataform/config/abr_box_defs.sql`, banner export tables `render_abr_*` / `mart_abr_boxes` |

If a task needs both sides → **stop**, ping in chat, agree who owns the change. Do not “quick edit” the other lane.

**Branch tip:** Rishi works on `rishi/…` branches; Sreeram on `sreeram/…` or current feature branch for banners only. Merge via PR; do not push over each other’s WIP.

---

## Done already (do not redo)

- Canon load drop-002 (HTR/K3/K9)
- Dual `stg_clean` (FF ∪ ABR)
- `format_schema` row `abr_persona_v1`
- `int_cut_attrs` arms via `canon_respondent.sample_arm` (HTR 273 / K3 25 / K9 125)
- `mart_stubs` live for drop-002 (~121 SELECT)
- Banner SQL scaffold: kids vs HTR, `%.1f`, `0.0%`, signed box defs (partial)

---

## Sreeram lane (banners / QA) — remaining

1. Run in order (BQ only, no Dataform model edits):
   - `config/abr_box_defs.sql`
   - `banners/01_compute_abr_boxes.sql`
   - `banners/02_render_htr.sql` → export
   - `banners/03_render_kids.sql` → export
2. Expand **box defs** for more questions (exciting, boring, theatre intent, …) — only edit `abr_box_defs.sql`.
3. QA vs reference `banner_wtabs_kids.csv` (spot-check TOP/T2B on like/funny/want).
4. Optional later: parameterize `drop-002` out of banner SQL into a var at top of each file (still banners lane).

**Hard stop for Sreeram:** do not open Dataform `definitions/*.sqlx` or Cloud Run.

---

## Rishi lane (pipeline / infra) — remaining

1. **Sync repo ↔ Dataform UI**  
   Pull feature branch; ensure UI matches repo for:
   - `definitions/stg_clean.sqlx`
   - `int_cut_attrs.sqlx` (canon arm join — may only exist in UI today; **commit it to repo under definitions/**)
   - `dim_*`, `fct_response`, `mart_stubs`  
   Hard stop: do not change banner SQL.

2. **Cloud Run ingest** (when IAM granted)  
   - Own: `pipeline/cloud_run_job/**`, `CLOUD_RUN_PERMISSIONS_REMINDER.md`  
   - Deploy job; prove drop-003-style load without touching banners.

3. **Genericize adapters**  
   - Own: `adapters/**`  
   - Stop hardcoding drop-002 filenames; drive from `study_registry` + GCS prefix.  
   - Do not change how banners read `mart_stubs`.

4. **Optional Dataform improvement (after Sreeram finishes current exports)**  
   - Native `scale_nets` path for ABR inside `mart_stubs`  
   - **Coordinate first** — overlaps conceptually with `abr_box_defs`; only start after Sreeram says current box exports are signed off, or put nets behind a new model name (e.g. `mart_stubs_v2`) so banners keep working.

5. **FF → canon migration** (optional, Rishi-only)  
   - New adapter; no banner file edits.

**Hard stop for Rishi:** do not edit `banners/**` or `config/abr_box_defs.sql`; do not DROP/replace `render_abr_*` / `mart_abr_boxes` while Sreeram is exporting.

---

## Shared BQ objects (read vs write)

| Object | Sreeram | Rishi |
|---|---|---|
| `svy.mart_stubs`, dims, fct, int_cut_attrs | **READ only** | WRITE via Dataform |
| `svy_config.abr_box_defs`, `abr_question_boxes` | WRITE | READ only |
| `svy.mart_abr_boxes`, `render_abr_*` | WRITE | Do not touch |
| `svy.canon_*` | READ | WRITE via adapter / Cloud Run |
| Dataform execution (full graph) | Avoid while exporting | OK on schedule; warn Sreeram if rebuilding stubs mid-QA |

---

## Suggested first messages to Rishi

> Own Dataform definitions + Cloud Run. Commit `int_cut_attrs` from UI into `definitions/`. Do not touch `pipeline/dataform/banners/` or `config/abr_box_defs.sql`. I’m finishing HTR/kids exports and box signing there.

---

## When overlap is unavoidable

Example: Rishi wants `mart_stubs` to emit NET rows that banners should use.

1. Rishi adds **new** model or columns (non-breaking).  
2. Sreeram switches render SQL after a checkpoint.  
3. Never both edit `03_render_kids.sql` and `mart_stubs.sqlx` in the same hour without a Slack “switching” note.
