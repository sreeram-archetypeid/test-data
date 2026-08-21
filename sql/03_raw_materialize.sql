-- Materialise the immutable raw layer from the external tables.
-- _FILE_NAME is only available on external tables; capturing it here is what
-- makes run_id (and therefore the 2.1X replicate model) possible.
CREATE OR REPLACE TABLE `ff_00_raw.raw_read_s21` AS
SELECT *, _FILE_NAME AS _source_file, CURRENT_TIMESTAMP() AS _loaded_at
FROM `ff_00_raw.ext_read_s21`;

CREATE OR REPLACE TABLE `ff_00_raw.raw_read_s22` AS
SELECT *, _FILE_NAME AS _source_file, CURRENT_TIMESTAMP() AS _loaded_at
FROM `ff_00_raw.ext_read_s22`;

CREATE OR REPLACE TABLE `ff_00_raw.raw_read_s23` AS
SELECT *, _FILE_NAME AS _source_file, CURRENT_TIMESTAMP() AS _loaded_at
FROM `ff_00_raw.ext_read_s23`;
