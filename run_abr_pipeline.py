import os
import re
import math
import pandas as pd
import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.cluster import KMeans

# ==============================================================================
# 1. STATISTICAL & MATH UTILITIES
# ==============================================================================

def wilson_interval(k, n, confidence=0.95):
    """Calculates Wilson score interval for a proportion (returns lower/upper %)."""
    if n == 0 or pd.isna(n):
        return (0.0, 0.0)
    z = 1.95996  # 95% CI
    p_hat = k / n
    denom = 1 + (z**2) / n
    center = (p_hat + (z**2) / (2 * n)) / denom
    spread = (z * math.sqrt((p_hat * (1 - p_hat) / n) + (z**2) / (4 * (n**2)))) / denom
    lower = max(0.0, center - spread) * 100
    upper = min(1.0, center + spread) * 100
    return round(lower, 1), round(upper, 1)

def spearman_rank_correlation(x, y):
    """Calculates Spearman rank correlation coefficient between two series."""
    if len(x) < 2:
        return 0.0
    rx = pd.Series(x).rank()
    ry = pd.Series(y).rank()
    d = rx - ry
    n = len(x)
    return 1.0 - (6.0 * (d**2).sum()) / (n * (n**2 - 1.0))

# ==============================================================================
# 2. VERBATIM HYGIENE & PROSE SCORING ENGINES
# ==============================================================================

def clean_verbatim(text):
    """
    Strips roleplay stage directions, tracks engagement count, and
    quarantines harness JSON artifacts.
    """
    if not isinstance(text, str) or not text.strip():
        return "", 0, False
    
    # Check for generation harness leak
    harness_keys = ["mixtureOfExperts", "residualRisks", "self-critique", "generationConfig"]
    if any(key in text for key in harness_keys):
        return "[QUARANTINED_HARNESS_JSON]", 0, True
    
    # Match [stage directions] and *stage directions*
    pattern = r'\[.*?\]|\*.*?\*'
    stage_dirs = re.findall(pattern, text)
    stage_count = len(stage_dirs)
    
    cleaned = re.sub(pattern, '', text).strip()
    return cleaned, stage_count, False

def score_prose_intent(text):
    """Deterministic NLP rubric scoring prose metrics on a 1-5 scale."""
    if not text or text == "[QUARANTINED_HARNESS_JSON]":
        return None, "UNSCORED"
    
    t = text.lower()
    if "n/a" in t or "not applicable" in t or t == "none":
        return None, "BASE_EXCLUDED_NA"
    if any(neg in t for neg in ["definitely not", "terrible", "ruined", "pass on this", "creepy", "won't pay"]):
        return 1, "SCORED_1_STRONG_NEG"
    if any(defer in t for defer in ["wait for streaming", "disney+", "wait for home", "netflix", "too expensive for theater"]):
        return 2, "SCORED_2_LOW_THEATRICAL_DEFER"
    if any(mod in t for mod in ["okay", "average", "typical", "indifferent", "maybe"]):
        return 3, "SCORED_3_NEUTRAL"
    if any(pos in t for pos in ["cute", "fun for kids", "might watch", "looks decent", "good family film"]):
        return 4, "SCORED_4_MODERATE_POS"
    if any(hi in t for hi in ["must see", "definitely watch", "opening day", "love air bud", "taking the whole family"]):
        return 5, "SCORED_5_STRONG_POS"
        
    return 3, "SCORED_3_DEFAULT_NEUTRAL"

# ==============================================================================
# 3. DATA RESHAPING & FACT TABLE ENGINE
# ==============================================================================

def reshape_file(file_path, panel_id):
    """Pivots wide survey rows into long fact records with exact reconciliation."""
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"Missing file: {file_path}")
        
    df = pd.read_csv(file_path)
    
    # Identify persona vs question columns
    persona_cols = [c for c in df.columns if not re.match(r'^Q\d+_', c)]
    q_cols = [c for c in df.columns if re.match(r'^Q\d+_', c)]
    q_indices = sorted(list(set([int(re.search(r'^Q(\d+)_', c).group(1)) for c in q_cols])))
    
    fact_rows = []
    
    for idx, row in df.iterrows():
        p_dict = {c: row[c] for c in persona_cols}
        p_dict['panel_id'] = panel_id
        p_dict['persona_id'] = f"{panel_id}_P{idx+1:02d}"
        
        for q_num in q_indices:
            q_text = row.get(f"Q{q_num}_question", None)
            if pd.isna(q_text):
                continue
                
            fact = p_dict.copy()
            fact['q_positional'] = q_num
            fact['question_text'] = str(q_text).strip()
            fact['meta'] = str(row.get(f"Q{q_num}_meta", "")).strip()
            fact['type'] = row.get(f"Q{q_num}_type", None)
            fact['rating_label'] = row.get(f"Q{q_num}_rating_label", "")
            fact['rating'] = row.get(f"Q{q_num}_rating", None)
            fact['selected_raw'] = str(row.get(f"Q{q_num}_selected", "")).strip()
            fact['qual_raw'] = str(row.get(f"Q{q_num}_qual", "")).strip()
            fact_rows.append(fact)
            
    fact_df = pd.DataFrame(fact_rows)
    
    # Reconciliation Check
    expected_rows = len(df) * len(q_indices)
    actual_rows = len(fact_df)
    print(f"[{panel_id}] Personas: {len(df)} | Qs: {len(q_indices)} | Expected Facts: {expected_rows} | Actual: {actual_rows}")
    assert expected_rows == actual_rows, f"Pivoting mismatch in {panel_id}!"
    
    return fact_df

# ==============================================================================
# 4. SCALE MAPPER & LATENT SCORER
# ==============================================================================

def apply_scale_rules(row):
    """
    Parses Q*_selected text, isolates sentinels, applies construct polarity,
    and returns Top Box, Top-2 Box, Bottom Box, and 0-100 Latent Score.
    """
    meta = row['meta']
    sel = row['selected_raw']
    
    if pd.isna(sel) or sel == "" or sel == "nan":
        return pd.Series([None, None, None, None, False], 
                         index=['latent_score', 'is_top_box', 'is_top2_box', 'is_bottom_box', 'is_sentinel'])
    
    # Check for Sentinels
    sentinel_terms = ["don't know", "unsure", "no opinion", "never saw", "not applicable", "other"]
    if any(s in sel.lower() for s in sentinel_terms):
        return pd.Series([None, False, False, False, True], 
                         index=['latent_score', 'is_top_box', 'is_top2_box', 'is_bottom_box', 'is_sentinel'])
    
    # Extract leading numeric code
    code_match = re.search(r'^(\d+)\.', sel)
    code = int(code_match.group(1)) if code_match else None
    
    latent_score = None
    top_box = False
    top2_box = False
    bottom_box = False
    
    # Apply Question-Specific Rules
    if meta in ['M_APPEAL_RATING', 'M_THEATRICAL_INTENT', 'M_RECOMMEND_LIFT']: # 5-Point Standard
        if code:
            latent_score = (code - 1) / 4.0 * 100.0
            top_box = (code == 5)
            top2_box = (code >= 4)
            bottom_box = (code <= 2)
            
    elif meta in ['M_HUMOR_FIT', 'M_NOSTALGIA_RESON', 'M_DOG_CGI_ACTION']: # 4-Point Standard
        if code:
            latent_score = (code - 1) / 3.0 * 100.0
            top_box = (code == 4)
            top2_box = (code >= 3)
            bottom_box = (code == 1)
            
    elif meta in ['M_SCARY_SENSORY', 'M_CONFUSION_PROBE']: # Negative Constructs (Code 4 = Best)
        if code:
            latent_score = (code - 1) / 3.0 * 100.0  # Assumes Code 4 is "Not at all"
            top_box = (code == 4)
            top2_box = (code >= 3)
            bottom_box = (code == 1)
            
    elif meta == 'M_STREAMING_DEFER': # 3-Point Inverted (Code 3 = Theater = 100)
        if code == 3: latent_score = 100.0; top_box = True; top2_box = True
        elif code == 2: latent_score = 50.0
        elif code == 1: latent_score = 0.0; bottom_box = True
        
    elif meta == 'M_PACING_LENGTH': # Centered Ideal Scale (Code 2 = Ideal = 100)
        if code == 2: latent_score = 100.0; top_box = True; top2_box = True
        elif code in [1, 3]: latent_score = 0.0; bottom_box = True

    return pd.Series([latent_score, top_box, top2_box, bottom_box, False], 
                     index=['latent_score', 'is_top_box', 'is_top2_box', 'is_bottom_box', 'is_sentinel'])

# ==============================================================================
# 5. PIPELINE EXECUTION ENGINE
# ==============================================================================

def main():
    print("=================================================================")
    print("AIR BUD RETURNS (ABR) SYNTHETIC PANEL PIPELINE")
    print("=================================================================\n")
    
    file_map = {
        "K9": "ABR-Trailer-Return-v.4 REV/42p.0.0-ABR--TReturnv4-K9-1   Results.csv",
        "K3": "ABR-Trailer-Return-v.4 REV/42p.0.0-ABR--TReturnv4-K3-1   Results.csv",
        "TR1": "ABR-Trailer-Return-v.4 REV/42p.0.0-ABR-TReturnv4-1   Results.csv"
    }
    
    # --------------------------------------------------------------------------
    # PHASE A & B: LOADING, PROFILE & RESHAPE RECONCILIATION
    # --------------------------------------------------------------------------
    fact_tables = []
    for pid, path in file_map.items():
        if os.path.exists(path):
            fact_tables.append(reshape_file(path, pid))
        else:
            print(f"WARNING: File {path} not found. Skipping {pid}.")
            
    if not fact_tables:
        print("ERROR: No CSV files found. Place CSV files in workspace to execute.")
        return
        
    full_fact = pd.concat(fact_tables, ignore_index=True)
    total_personas = full_fact['persona_id'].nunique()
    print(f"\n[PHASE B SUCCESS] Unified Long Fact Table Built: {len(full_fact)} rows ({total_personas} Personas)")
    
    # Check Q*_rating fill rate
    rating_fill = full_fact['rating'].notna().mean() * 100
    print(f"[AUDIT] Fill Rate of raw Q*_rating numeric column: {rating_fill:.2f}%")
    print("        -> Quantitative signal isolated to Q*_selected text parser.")

    # --------------------------------------------------------------------------
    # PHASE C: SCALE RESOLUTION & LATENT SCORING
    # --------------------------------------------------------------------------
    scale_metrics = full_fact.apply(apply_scale_rules, axis=1)
    full_fact = pd.concat([full_fact, scale_metrics], axis=1)
    
    # --------------------------------------------------------------------------
    # PHASE D & E: VERBATIM HYGIENE, PROSE SCORING & THEMES
    # --------------------------------------------------------------------------
    clean_results = full_fact['qual_raw'].apply(clean_verbatim)
    full_fact['qual_clean'] = [r[0] for r in clean_results]
    full_fact['stage_dir_count'] = [r[1] for r in clean_results]
    full_fact['is_harness'] = [r[2] for r in clean_results]
    
    # Prose Intent Scoring
    prose_scores = full_fact['qual_clean'].apply(score_prose_intent)
    full_fact['prose_score'] = [p[0] for p in prose_scores]
    full_fact['prose_flag'] = [p[1] for p in prose_scores]
    
    # Theme Codeframe Rules
    audio_pattern = r'loud|yelling|buzzer|screaming|noise|sound mix'
    cgi_pattern = r'cgi|fake|mouth|creepy|uncanny'
    nost_pattern = r'original|grew up|nostalgia|childhood|90s'
    
    full_fact['theme_audio'] = full_fact['qual_clean'].str.contains(audio_pattern, case=False, regex=True)
    full_fact['theme_cgi'] = full_fact['qual_clean'].str.contains(cgi_pattern, case=False, regex=True)
    full_fact['theme_nostalgia'] = full_fact['qual_clean'].str.contains(nost_pattern, case=False, regex=True)

    # --------------------------------------------------------------------------
    # PHASE F: STATISTICAL REPORTING & CROSS-PANEL VALIDATION
    # --------------------------------------------------------------------------
    print("\n-----------------------------------------------------------------")
    print("PHASE F: HEADLINE METRICS (N = %d Personas)" % total_personas)
    print("-----------------------------------------------------------------")
    
    headline_metas = ['M_APPEAL_RATING', 'M_THEATRICAL_INTENT', 'M_NOSTALGIA_RESON', 
                      'M_DOG_CGI_ACTION', 'M_SCARY_SENSORY', 'M_RECOMMEND_LIFT']
    
    summary_rows = []
    for meta in headline_metas:
        sub = full_fact[(full_fact['meta'] == meta) & (~full_fact['is_sentinel'])].copy()
        n_base = len(sub)
        
        if n_base == 0:
            continue
            
        tb_cnt = sub['is_top_box'].sum()
        t2b_cnt = sub['is_top2_box'].sum()
        
        tb_pct = (tb_cnt / n_base) * 100
        t2b_pct = (t2b_cnt / n_base) * 100
        
        tb_low, tb_upp = wilson_interval(tb_cnt, n_base)
        t2b_low, t2b_upp = wilson_interval(t2b_cnt, n_base)
        
        mean_latent = sub['latent_score'].mean()
        
        summary_rows.append({
            'Meta ID': meta,
            'Base (n)': n_base,
            'Top Box %': f"{tb_pct:.1f}% [{tb_low}%, {tb_upp}%]",
            'Top-2 Box %': f"{t2b_pct:.1f}% [{t2b_low}%, {t2b_upp}%]",
            'Latent Mean': f"{mean_latent:.1f}"
        })
        
    summary_df = pd.DataFrame(summary_rows)
    print(summary_df.to_string(index=False))

    # Cross-Panel Validation (K9 vs K3)
    k9_df = full_fact[full_fact['panel_id'] == 'K9']
    k3_df = full_fact[full_fact['panel_id'] == 'K3']
    
    if len(k9_df) > 0 and len(k3_df) > 0:
        common_metas = set(k9_df['meta']).intersection(set(k3_df['meta']))
        movements = []
        
        for m in common_metas:
            m1 = k9_df[k9_df['meta'] == m]['latent_score'].dropna().mean()
            m2 = k3_df[k3_df['meta'] == m]['latent_score'].dropna().mean()
            if pd.notna(m1) and pd.notna(m2):
                movements.append({'meta': m, 'k9_mean': m1, 'k3_mean': m2, 'abs_diff': abs(m1 - m2)})
                
        comp_df = pd.DataFrame(movements)
        malm = comp_df['abs_diff'].mean()
        spearman_r = spearman_rank_correlation(comp_df['k9_mean'], comp_df['k3_mean'])
        
        print("\n-----------------------------------------------------------------")
        print("CROSS-PANEL VALIDATION (K9 vs. K3 Repeatability)")
        print("-----------------------------------------------------------------")
        print(f"Items Evaluated                     : {len(comp_df)}")
        print(f"Mean Absolute Latent Movement (MALM): {malm:.2f} Latent Points")
        print(f"Rank-Order Agreement (Spearman r)   : {spearman_r:.3f}")
        print(f"Empirical Uncertainty Margin        : ±{malm:.2f} Points")

    print("\n=================================================================")
    print("PIPELINE EXECUTION COMPLETE")
    print("=================================================================")

if __name__ == "__main__":
    main()