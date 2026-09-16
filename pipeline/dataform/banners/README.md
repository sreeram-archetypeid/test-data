# ABR W-Tabs banners (drop-002 instance)

House rules: `FORMAT('%.1f')`, missing → `0.0%`, boxes signed in config.

## What this adds (like Final W-Tabs)

| Output table | Contents |
|---|---|
| `abr_respondent_meta` | Clean persona cuts: panel, gender, ethnicity, location, adoption, children, age bands |
| `mart_abr_banner_meta` | Long tidy banner: every Q × option × meta group |
| `render_abr_persona_meta` | Persona inventory tables (age/gender/ethnicity/…) by 4-6 / 7-12 / 12-64 |
| `render_abr_kids_wtabs` | Kids questionnaire + panel/gender/age/ethnicity + boxes |
| `render_abr_htr_wtabs` | HTR questionnaire + gender/age/ethnicity/location/adoption/children + boxes |

**Not used as cuts** (too sparse / free text): hobbies, persona prose, most `aat_*` narratives.

## Run order (BigQuery)

```
config/abr_box_defs.sql
banners/01_compute_abr_boxes.sql
banners/04_build_abr_respondent_meta.sql
banners/05_mart_abr_banner_meta.sql
banners/06_render_persona_meta.sql          → export first (demo book)
banners/07_render_kids_wtabs_meta.sql       → export kids W-Tabs
banners/08_render_htr_wtabs_meta.sql        → export HTR W-Tabs
```

Optional simpler books (earlier): `02_render_htr.sql`, `03_render_kids.sql`.

## Meta groups in `mart_abr_banner_meta`

`TOTAL`, `PANEL` (4-6 / 7-12 / 12-64), `GENDER`, `ETHNICITY`, `LOCATION`, `ADOPTION`, `AGE_BAND`, `PANEL_GENDER`, `QUADRANTS`, `CHILDREN` (HTR).

## Genericity note

Logic is **format-pack / ABR-shaped**. Filenames still use `drop-002` in SQL — change that var when running another ABR drop with the same instruments. New question wording → extend `abr_box_defs` / `abr_question_boxes`.
