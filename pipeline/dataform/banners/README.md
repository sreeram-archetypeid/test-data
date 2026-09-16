# ABR banners — do this in order (BigQuery)

House rules forever:
- Percents: `FORMAT('%.1f', …)` → e.g. `16.7%`
- Missing cell → `0.0%`
- Top / T2B / Bottom are **signed** in `svy_config.abr_box_defs` (not guessed)

## Steps

1. **Sign boxes** (once; edit later to add more questions)  
   Run: `pipeline/dataform/config/abr_box_defs.sql`

2. **Compute boxes from current stubs**  
   Run: `pipeline/dataform/banners/01_compute_abr_boxes.sql`  
   Check smoke at bottom: K3/K9 trailer-like TOP/T2B/BOTTOM should be non-null.

3. **Render HTR book**  
   Run: `pipeline/dataform/banners/02_render_htr.sql`  
   Export: `SELECT * FROM archetypeid-staging.svy.render_abr_htr_pcnt`

4. **Render kids book (4-6 vs 7-12)**  
   Run: `pipeline/dataform/banners/03_render_kids.sql`  
   Export: `SELECT * FROM archetypeid-staging.svy.render_abr_kids_pcnt`

## Adding Top/T2B/Bottom for another question

1. Get distinct cleaned options from data.
2. Add 3 rows to `abr_box_defs` (TOP / T2B / BOTTOM) with exact labels.
3. Add a row to `abr_question_boxes` (regex on question text + arm if kids).
4. Re-run steps 2–4.

## Why kids need per-arm scales

K3 and K9 use different words for the same idea (`I liked it a lot` vs `I liked it a lot!`).  
One shared top-box label would miss one panel — so K3/K9 each have their own `scale_id`.
