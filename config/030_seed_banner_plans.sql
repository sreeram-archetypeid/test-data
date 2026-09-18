-- =====================================================================
-- Banner plans.
--   ff_ban2   reproduces the 305-9113 column spine (51 printed columns
--             from 26 config rows; nest_by_cell doubles the nested ones)
--   abr_ban1  monadic, so nest_by_cell is FALSE everywhere and the
--             T1_/T2_ header band collapses to nothing
-- =====================================================================

DELETE FROM `archetypeid-staging.banner_config.banner_plan` WHERE banner_plan_id IN ('ff_ban2','abr_ban1');
INSERT INTO `archetypeid-staging.banner_config.banner_plan` VALUES
 ('ff_ban2', '305-9113 Arena FatalFury ConceptTest Ban2','arena_ff_v1','7 printed groups, 2 cells'),
 ('abr_ban1','Air Bud Returns monadic banner','arena_abr_v1','Single cell. Age-panel cuts.');

-- Scoped delete: hand-added plans for other drops are preserved.
DELETE FROM `archetypeid-staging.banner_config.cut_def` WHERE banner_plan_id IN ('ff_ban2','abr_ban1');

-- ---- ff_ban2 : leaf helpers (not printed) ---------------------------
INSERT INTO `archetypeid-staging.banner_config.cut_def` VALUES
 ('ff_ban2','lf_men',  NULL,0,NULL,0,FALSE,FALSE,'attr','gender',['Man'],   NULL,NULL,NULL,NULL,NULL,NULL),
 ('ff_ban2','lf_women',NULL,0,NULL,0,FALSE,FALSE,'attr','gender',['Woman'], NULL,NULL,NULL,NULL,NULL,NULL),
 ('ff_ban2','lf_lt35', NULL,0,NULL,0,FALSE,FALSE,'attr','age_group',['<35'],NULL,NULL,NULL,NULL,NULL,NULL),
 ('ff_ban2','lf_35p',  NULL,0,NULL,0,FALSE,FALSE,'attr','age_group',['35+'],NULL,NULL,NULL,NULL,NULL,NULL);

-- ---- ff_ban2 : spine -------------------------------------------------
INSERT INTO `archetypeid-staging.banner_config.cut_def` VALUES
 ('ff_ban2','total',  NULL,0,'Total',  0,TRUE,FALSE,'all',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
 ('ff_ban2','concept',NULL,0,'CONCEPT',10,TRUE,TRUE,'all',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL);

-- ---- ff_ban2 : QUADRANTS --------------------------------------------
INSERT INTO `archetypeid-staging.banner_config.cut_def` VALUES
 ('ff_ban2','q_men_lt35',  'QUADRANTS',1,'Men <35',  1,TRUE,TRUE,'and',NULL,NULL,NULL,NULL,NULL,NULL,['lf_men','lf_lt35'],  30),
 ('ff_ban2','q_men_35p',   'QUADRANTS',1,'Men 35+',  2,TRUE,TRUE,'and',NULL,NULL,NULL,NULL,NULL,NULL,['lf_men','lf_35p'],   30),
 ('ff_ban2','q_women_lt35','QUADRANTS',1,'Women <35',3,TRUE,TRUE,'and',NULL,NULL,NULL,NULL,NULL,NULL,['lf_women','lf_lt35'],30),
 ('ff_ban2','q_women_35p', 'QUADRANTS',1,'Women 35+',4,TRUE,TRUE,'and',NULL,NULL,NULL,NULL,NULL,NULL,['lf_women','lf_35p'], 30);

-- ---- ff_ban2 : FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1) -----------
INSERT INTO `archetypeid-staging.banner_config.cut_def` VALUES
 ('ff_ban2','fam_lot',   'FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)',2,'Know a lot',    1,TRUE,TRUE,'response',NULL,NULL,'VGFRAN1','(?i)fatal fury','in', [1],NULL,30),
 ('ff_ban2','fam_little','FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)',2,'Know a little', 2,TRUE,TRUE,'response',NULL,NULL,'VGFRAN1','(?i)fatal fury','in', [2],NULL,30),
 ('ff_ban2','fam_heard', 'FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)',2,'Heard of',      3,TRUE,TRUE,'response',NULL,NULL,'VGFRAN1','(?i)fatal fury','in', [3],NULL,30),
 ('ff_ban2','fam_never', 'FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)',2,'Never Heard of',4,TRUE,TRUE,'response',NULL,NULL,'VGFRAN1','(?i)fatal fury','in', [4],NULL,30),
 ('ff_ban2','fam_know',  'FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)',2,'Total Know',    5,TRUE,TRUE,'response',NULL,NULL,'VGFRAN1','(?i)fatal fury','lte',[3],NULL,30),
 ('ff_ban2','fam_non',   'FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)',2,'Non-Players',   6,TRUE,TRUE,'response',NULL,NULL,'VGFRAN1','(?i)fatal fury','gte',[4],NULL,30);

-- ---- ff_ban2 : GENRE FANS (P1 @ GFAN1) ------------------------------
INSERT INTO `archetypeid-staging.banner_config.cut_def` VALUES
 ('ff_ban2','gf_action','GENRE FANS (P1 @ GFAN1)',3,'Action',      1,TRUE,TRUE,'response',NULL,NULL,'GFAN1','(?i)action',       'in',[1],NULL,30),
 ('ff_ban2','gf_ma',    'GENRE FANS (P1 @ GFAN1)',3,'Martial Arts',2,TRUE,TRUE,'response',NULL,NULL,'GFAN1','(?i)martial arts', 'in',[1],NULL,30),
 ('ff_ban2','gf_anime', 'GENRE FANS (P1 @ GFAN1)',3,'Anime',       3,TRUE,TRUE,'response',NULL,NULL,'GFAN1','(?i)anime',        'in',[1],NULL,30);

-- ---- ff_ban2 : GAMING / MOVIEGOING (@ ACTIVITIES) -------------------
INSERT INTO `archetypeid-staging.banner_config.cut_def` VALUES
 ('ff_ban2','gm_daily','GAMING (P2 @ ACTIVITIES)',4,'Daily',            1,TRUE,TRUE,'response',NULL,NULL,'ACTIVITIES','(?i)video game','in',[1],    NULL,30),
 ('ff_ban2','gm_wkmo', 'GAMING (P2 @ ACTIVITIES)',4,'Weekly/Monthly',   2,TRUE,TRUE,'response',NULL,NULL,'ACTIVITIES','(?i)video game','in',[2,3],  NULL,30),
 ('ff_ban2','mv_wkmo', 'MOVIEGOING (P1 @ ACTIVITIES)',5,'Weekly/Monthly',  1,TRUE,TRUE,'response',NULL,NULL,'ACTIVITIES','(?i)theater','in',[1,2,3],NULL,30),
 ('ff_ban2','mv_2to6', 'MOVIEGOING (P1 @ ACTIVITIES)',5,'Every 2-6 Months',2,TRUE,TRUE,'response',NULL,NULL,'ACTIVITIES','(?i)theater','in',[4],    NULL,30);

-- ---- ff_ban2 : ETHNICITY (quota definitions) ------------------------
INSERT INTO `archetypeid-staging.banner_config.cut_def` VALUES
 ('ff_ban2','eth_cao','ETHNICITY (QUOTA DEFINITIONS)',6,'Caucasian/Asian/Other',1,TRUE,TRUE,'attr','ethnicity',['White / Caucasian','Asian or Pacific Islander'],NULL,NULL,NULL,NULL,NULL,30),
 ('ff_ban2','eth_hl', 'ETHNICITY (QUOTA DEFINITIONS)',6,'Hispanic/Latino',      2,TRUE,TRUE,'attr','ethnicity',['Latino / Hispanic'],NULL,NULL,NULL,NULL,NULL,30),
 ('ff_ban2','eth_aa', 'ETHNICITY (QUOTA DEFINITIONS)',6,'AA/Black',             3,TRUE,TRUE,'attr','ethnicity',['Black / African American'],NULL,NULL,NULL,NULL,NULL,30);

-- ---- ff_ban2 : FATAL FURY FANSHIP (P3 DOWN @ VGFRAN2) ---------------
INSERT INTO `archetypeid-staging.banner_config.cut_def` VALUES
 ('ff_ban2','fan_very','FATAL FURY FANSHIP (P3 DOWN @ VGFRAN2)',7,'Very Much Fan',1,TRUE,TRUE,'response',NULL,NULL,'VGFRAN2','(?i)fatal fury','in', [1],NULL,30),
 ('ff_ban2','fan_some','FATAL FURY FANSHIP (P3 DOWN @ VGFRAN2)',7,'Somewhat Fan', 2,TRUE,TRUE,'response',NULL,NULL,'VGFRAN2','(?i)fatal fury','in', [2],NULL,30),
 ('ff_ban2','fan_tot', 'FATAL FURY FANSHIP (P3 DOWN @ VGFRAN2)',7,'Total Fans',   3,TRUE,TRUE,'response',NULL,NULL,'VGFRAN2','(?i)fatal fury','lte',[2],NULL,30),
 ('ff_ban2','fan_not', 'FATAL FURY FANSHIP (P3 DOWN @ VGFRAN2)',7,'Not a Fan',    4,TRUE,TRUE,'response',NULL,NULL,'VGFRAN2','(?i)fatal fury','gte',[3],NULL,30);


-- =====================================================================
-- abr_ban1 : monadic. nest_by_cell FALSE throughout.
-- Cuts are audience panels and demographics only, because ABR has no
-- pre-exposure attitudinal battery comparable to VGFRAN/GFAN.
-- =====================================================================
INSERT INTO `archetypeid-staging.banner_config.cut_def` VALUES
 ('abr_ban1','lf_men',  NULL,0,NULL,0,FALSE,FALSE,'attr','gender',['Man'],  NULL,NULL,NULL,NULL,NULL,NULL),
 ('abr_ban1','lf_women',NULL,0,NULL,0,FALSE,FALSE,'attr','gender',['Woman'],NULL,NULL,NULL,NULL,NULL,NULL),
 ('abr_ban1','total',   NULL,0,'Total',0,TRUE,FALSE,'all',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),

 ('abr_ban1','ap_46',  'AGE PANEL',1,'4-6',  1,TRUE,FALSE,'attr','age_band',['4-6'],  NULL,NULL,NULL,NULL,NULL,15),
 ('abr_ban1','ap_79',  'AGE PANEL',1,'7-9',  2,TRUE,FALSE,'attr','age_band',['7-9'],  NULL,NULL,NULL,NULL,NULL,15),
 ('abr_ban1','ap_1012','AGE PANEL',1,'10-12',3,TRUE,FALSE,'attr','age_band',['10-12'],NULL,NULL,NULL,NULL,NULL,15),
 ('abr_ban1','ap_ad',  'AGE PANEL',1,'Adults',4,TRUE,FALSE,'or',NULL,NULL,NULL,NULL,NULL,NULL,['lf_ad1','lf_ad2'],20),
 ('abr_ban1','lf_ad1', NULL,0,NULL,0,FALSE,FALSE,'attr','age_band',['18-34'],NULL,NULL,NULL,NULL,NULL,NULL),
 ('abr_ban1','lf_ad2', NULL,0,NULL,0,FALSE,FALSE,'attr','age_band',['35-54'],NULL,NULL,NULL,NULL,NULL,NULL),

 ('abr_ban1','g_men',  'GENDER',2,'Boys/Men',  1,TRUE,FALSE,'attr','gender',['Man'],  NULL,NULL,NULL,NULL,NULL,20),
 ('abr_ban1','g_women','GENDER',2,'Girls/Women',2,TRUE,FALSE,'attr','gender',['Woman'],NULL,NULL,NULL,NULL,NULL,20),

 ('abr_ban1','e_cao','ETHNICITY',3,'Caucasian/Asian/Other',1,TRUE,FALSE,'attr','ethnicity',['White / Caucasian','Asian or Pacific Islander'],NULL,NULL,NULL,NULL,NULL,20),
 ('abr_ban1','e_hl', 'ETHNICITY',3,'Hispanic/Latino',      2,TRUE,FALSE,'attr','ethnicity',['Latino / Hispanic'],NULL,NULL,NULL,NULL,NULL,20),
 ('abr_ban1','e_aa', 'ETHNICITY',3,'AA/Black',             3,TRUE,FALSE,'attr','ethnicity',['Black / African American'],NULL,NULL,NULL,NULL,NULL,20);


-- =====================================================================
-- NETs. The only editorial grouping that cannot be read from the data.
-- =====================================================================
DELETE FROM `archetypeid-staging.banner_config.net_def` WHERE format_id IN ('arena_ff_v1','arena_abr_v1');
INSERT INTO `archetypeid-staging.banner_config.net_def`
 (format_id, meta, item_pattern, net_label, codes, net_sort)
VALUES
 ('arena_ff_v1','POSTINT',   NULL,'NET: Total Interested',      [1,2],  5),
 ('arena_ff_v1','POSTINT',   NULL,'NET: Total Not Interested',  [3,4],  6),
 ('arena_ff_v1','VGFRAN1',   NULL,'Total Know',                 [1,2,3],5),
 ('arena_ff_v1','VGFRAN2',   NULL,'Total Fans',                 [1,2],  5),
 ('arena_ff_v1','VGFRAN3',   NULL,'NET: Total Interested',      [1,2],  5),
 ('arena_ff_v1','ACTIVITIES',NULL,'NET: Weekly/Monthly',        [2,3],  5),
 ('arena_ff_v1','VIABLE1',   NULL,'NET: Total Interested',      [1,2],  5),
 ('arena_ff_v1','VIABLE2',   NULL,'NET: Total Interested',      [1,2],  5);
