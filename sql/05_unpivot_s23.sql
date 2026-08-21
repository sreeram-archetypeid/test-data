-- Section 2.3: 36 question blocks -> 36 fact rows per source row.
CREATE OR REPLACE TABLE `ff_10_staging.stg_response_s23` AS
SELECT
  archetype_id,
  LOWER(REGEXP_EXTRACT(_source_file, r'([^/]+)\.csv$')) AS run_id,
  q_idx, question_text, meta, q_type, rating_label, rating, selected, qual
FROM `ff_00_raw.raw_read_s23`
UNPIVOT (
  (question_text, meta, q_type, rating_label, rating, selected, qual)
  FOR q_idx IN (
    (Q1_question, Q1_meta, Q1_type, Q1_rating_label, Q1_rating, Q1_selected, Q1_qual) AS 1,
    (Q2_question, Q2_meta, Q2_type, Q2_rating_label, Q2_rating, Q2_selected, Q2_qual) AS 2,
    (Q3_question, Q3_meta, Q3_type, Q3_rating_label, Q3_rating, Q3_selected, Q3_qual) AS 3,
    (Q4_question, Q4_meta, Q4_type, Q4_rating_label, Q4_rating, Q4_selected, Q4_qual) AS 4,
    (Q5_question, Q5_meta, Q5_type, Q5_rating_label, Q5_rating, Q5_selected, Q5_qual) AS 5,
    (Q6_question, Q6_meta, Q6_type, Q6_rating_label, Q6_rating, Q6_selected, Q6_qual) AS 6,
    (Q7_question, Q7_meta, Q7_type, Q7_rating_label, Q7_rating, Q7_selected, Q7_qual) AS 7,
    (Q8_question, Q8_meta, Q8_type, Q8_rating_label, Q8_rating, Q8_selected, Q8_qual) AS 8,
    (Q9_question, Q9_meta, Q9_type, Q9_rating_label, Q9_rating, Q9_selected, Q9_qual) AS 9,
    (Q10_question, Q10_meta, Q10_type, Q10_rating_label, Q10_rating, Q10_selected, Q10_qual) AS 10,
    (Q11_question, Q11_meta, Q11_type, Q11_rating_label, Q11_rating, Q11_selected, Q11_qual) AS 11,
    (Q12_question, Q12_meta, Q12_type, Q12_rating_label, Q12_rating, Q12_selected, Q12_qual) AS 12,
    (Q13_question, Q13_meta, Q13_type, Q13_rating_label, Q13_rating, Q13_selected, Q13_qual) AS 13,
    (Q14_question, Q14_meta, Q14_type, Q14_rating_label, Q14_rating, Q14_selected, Q14_qual) AS 14,
    (Q15_question, Q15_meta, Q15_type, Q15_rating_label, Q15_rating, Q15_selected, Q15_qual) AS 15,
    (Q16_question, Q16_meta, Q16_type, Q16_rating_label, Q16_rating, Q16_selected, Q16_qual) AS 16,
    (Q17_question, Q17_meta, Q17_type, Q17_rating_label, Q17_rating, Q17_selected, Q17_qual) AS 17,
    (Q18_question, Q18_meta, Q18_type, Q18_rating_label, Q18_rating, Q18_selected, Q18_qual) AS 18,
    (Q19_question, Q19_meta, Q19_type, Q19_rating_label, Q19_rating, Q19_selected, Q19_qual) AS 19,
    (Q20_question, Q20_meta, Q20_type, Q20_rating_label, Q20_rating, Q20_selected, Q20_qual) AS 20,
    (Q21_question, Q21_meta, Q21_type, Q21_rating_label, Q21_rating, Q21_selected, Q21_qual) AS 21,
    (Q22_question, Q22_meta, Q22_type, Q22_rating_label, Q22_rating, Q22_selected, Q22_qual) AS 22,
    (Q23_question, Q23_meta, Q23_type, Q23_rating_label, Q23_rating, Q23_selected, Q23_qual) AS 23,
    (Q24_question, Q24_meta, Q24_type, Q24_rating_label, Q24_rating, Q24_selected, Q24_qual) AS 24,
    (Q25_question, Q25_meta, Q25_type, Q25_rating_label, Q25_rating, Q25_selected, Q25_qual) AS 25,
    (Q26_question, Q26_meta, Q26_type, Q26_rating_label, Q26_rating, Q26_selected, Q26_qual) AS 26,
    (Q27_question, Q27_meta, Q27_type, Q27_rating_label, Q27_rating, Q27_selected, Q27_qual) AS 27,
    (Q28_question, Q28_meta, Q28_type, Q28_rating_label, Q28_rating, Q28_selected, Q28_qual) AS 28,
    (Q29_question, Q29_meta, Q29_type, Q29_rating_label, Q29_rating, Q29_selected, Q29_qual) AS 29,
    (Q30_question, Q30_meta, Q30_type, Q30_rating_label, Q30_rating, Q30_selected, Q30_qual) AS 30,
    (Q31_question, Q31_meta, Q31_type, Q31_rating_label, Q31_rating, Q31_selected, Q31_qual) AS 31,
    (Q32_question, Q32_meta, Q32_type, Q32_rating_label, Q32_rating, Q32_selected, Q32_qual) AS 32,
    (Q33_question, Q33_meta, Q33_type, Q33_rating_label, Q33_rating, Q33_selected, Q33_qual) AS 33,
    (Q34_question, Q34_meta, Q34_type, Q34_rating_label, Q34_rating, Q34_selected, Q34_qual) AS 34,
    (Q35_question, Q35_meta, Q35_type, Q35_rating_label, Q35_rating, Q35_selected, Q35_qual) AS 35,
    (Q36_question, Q36_meta, Q36_type, Q36_rating_label, Q36_rating, Q36_selected, Q36_qual) AS 36
  )
);
