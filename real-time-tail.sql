-- Run this once after the original 13-check CAGG lab, in the same database.
-- This is exactly phase 7 of cagg.sql; it does not recreate the schema.
\set ON_ERROR_STOP on
\pset pager off
\timing on
SET TIME ZONE 'UTC';

\echo PHASE 7: prove the real-time tail without another refresh
-- Historical corrections above required explicit refresh. In real-time mode,
-- readings newer than the materialization watermark are queried from raw data.
ALTER MATERIALIZED VIEW ghw_cagg.hourly_temperature
SET (timescaledb.materialized_only = false);
SELECT ghw_cagg.assert_true(
    'real_time_mode_enabled',
    EXISTS (SELECT 1 FROM timescaledb_information.continuous_aggregates
            WHERE view_schema = 'ghw_cagg'
              AND view_name = 'hourly_temperature' AND NOT materialized_only),
    jsonb_build_object('materialized_only', false)
);

-- The previous refresh ended at 2026-10-08 00:00 UTC. Do not refresh again.
INSERT INTO ghw_cagg.readings VALUES ('2026-10-08 00:10:00+00', 1, 30.00);
SELECT ghw_cagg.assert_true(
    'real_time_tail_visible_without_refresh',
    count(*) = 1 AND min(average_c) = 30.00 AND min(minimum_c) = 30.00
    AND min(maximum_c) = 30.00 AND min(reading_count) = 1,
    jsonb_build_object('view_rows', count(*), 'average_c', min(average_c),
                      'reading_count', min(reading_count))
) FROM ghw_cagg.hourly_temperature
WHERE bucket = TIMESTAMPTZ '2026-10-08 00:00:00+00' AND sensor_id = 1;

-- Resolve the genuine backing hypertable through metadata rather than assume
-- an internal ID. Read it directly to distinguish real-time raw data from
-- already-materialized rows.
DO $$
DECLARE
    backing_schema name;
    backing_table name;
    stored_rows bigint;
BEGIN
    SELECT materialization_hypertable_schema, materialization_hypertable_name
    INTO STRICT backing_schema, backing_table
    FROM timescaledb_information.continuous_aggregates
    WHERE view_schema = 'ghw_cagg' AND view_name = 'hourly_temperature';
    EXECUTE format('SELECT count(*) FROM %I.%I WHERE bucket = $1',
                   backing_schema, backing_table)
    INTO stored_rows
    USING TIMESTAMPTZ '2026-10-08 00:00:00+00';
    PERFORM ghw_cagg.assert_true(
        'real_time_tail_is_not_materialized', stored_rows = 0,
        jsonb_build_object('backing_relation',
                           format('%I.%I', backing_schema, backing_table),
                           'stored_tail_rows', stored_rows)
    );
END
$$;
SELECT ghw_cagg.assert_true(
    'real_time_view_matches_all_raw_data', count(*) = 0,
    jsonb_build_object('mismatched_buckets', count(*))
) FROM ghw_cagg.mismatched_buckets;
SELECT * FROM ghw_cagg.hourly_temperature
WHERE bucket >= TIMESTAMPTZ '2026-10-08 00:00:00+00'
ORDER BY bucket, sensor_id;
