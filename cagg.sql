-- Genuine TimescaleDB continuous aggregate lab, for a fresh dedicated database.
-- Synthetic temperature data only; no cloud resources or credentials required.
-- Run with: psql -X --set=ON_ERROR_STOP=1 --file=cagg.sql DATABASE
-- Existing ghw_cagg objects intentionally cause failure; nothing is dropped.
\set ON_ERROR_STOP on
\pset pager off
\timing on
SET TIME ZONE 'UTC';

CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE SCHEMA ghw_cagg;

CREATE TABLE ghw_cagg.checks (
    test_name text PRIMARY KEY,
    passed boolean NOT NULL CHECK (passed),
    observed jsonb NOT NULL,
    checked_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE FUNCTION ghw_cagg.assert_true(
    name text, condition boolean, observation jsonb
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: %; observed: %', name, observation;
    END IF;
    INSERT INTO ghw_cagg.checks(test_name, passed, observed)
    VALUES (name, true, observation);
    RAISE NOTICE 'PASS: %; observed: %', name, observation;
END
$$;

\echo PHASE 1: create a real hypertable and insert deterministic readings
CREATE TABLE ghw_cagg.readings (
    observed_at timestamptz NOT NULL,
    sensor_id smallint NOT NULL CHECK (sensor_id IN (1, 2)),
    temperature_c numeric(6, 2) NOT NULL,
    PRIMARY KEY (observed_at, sensor_id)
);
SELECT create_hypertable(
    'ghw_cagg.readings', 'observed_at',
    chunk_time_interval => INTERVAL '1 day'
);

-- Seven complete UTC days, with two readings every minute (20,160 rows).
-- The formula is deterministic; all expected aggregate values are read from
-- the actual hypertable rather than generated separately in application code.
INSERT INTO ghw_cagg.readings(observed_at, sensor_id, temperature_c)
SELECT TIMESTAMPTZ '2026-10-01 00:00:00+00' + minute_no * INTERVAL '1 minute',
       sensor_id,
       (18 + 2 * sensor_id + (minute_no % 120)::numeric / 20)::numeric(6, 2)
FROM generate_series(0, 10079) AS minutes(minute_no)
CROSS JOIN generate_series(1, 2) AS sensors(sensor_id);
ANALYZE ghw_cagg.readings;

SELECT ghw_cagg.assert_true(
    'hypertable_registered',
    EXISTS (SELECT 1 FROM timescaledb_information.hypertables
            WHERE hypertable_schema = 'ghw_cagg' AND hypertable_name = 'readings'),
    jsonb_build_object('relation', 'ghw_cagg.readings')
);
SELECT ghw_cagg.assert_true(
    'baseline_raw_rows', count(*) = 20160,
    jsonb_build_object('actual_rows', count(*), 'sensors', count(DISTINCT sensor_id))
) FROM ghw_cagg.readings;

\echo PHASE 2: define hourly avg/min/max/count and explicitly materialize
CREATE MATERIALIZED VIEW ghw_cagg.hourly_temperature
WITH (timescaledb.continuous, timescaledb.materialized_only = true) AS
SELECT time_bucket(INTERVAL '1 hour', observed_at) AS bucket,
       sensor_id,
       avg(temperature_c) AS average_c,
       min(temperature_c) AS minimum_c,
       max(temperature_c) AS maximum_c,
       count(*) AS reading_count
FROM ghw_cagg.readings
GROUP BY time_bucket(INTERVAL '1 hour', observed_at), sensor_id
WITH NO DATA;

-- This ordinary view always recomputes the truth from the raw hypertable.
CREATE VIEW ghw_cagg.raw_hourly_truth AS
SELECT time_bucket(INTERVAL '1 hour', observed_at) AS bucket,
       sensor_id,
       avg(temperature_c) AS average_c,
       min(temperature_c) AS minimum_c,
       max(temperature_c) AS maximum_c,
       count(*) AS reading_count
FROM ghw_cagg.readings
GROUP BY time_bucket(INTERVAL '1 hour', observed_at), sensor_id;

CREATE VIEW ghw_cagg.mismatched_buckets AS
SELECT coalesce(raw.bucket, materialized.bucket) AS bucket,
       coalesce(raw.sensor_id, materialized.sensor_id) AS sensor_id,
       raw.average_c AS raw_average_c,
       materialized.average_c AS materialized_average_c,
       raw.minimum_c AS raw_minimum_c,
       materialized.minimum_c AS materialized_minimum_c,
       raw.maximum_c AS raw_maximum_c,
       materialized.maximum_c AS materialized_maximum_c,
       raw.reading_count AS raw_count,
       materialized.reading_count AS materialized_count
FROM ghw_cagg.raw_hourly_truth AS raw
FULL OUTER JOIN ghw_cagg.hourly_temperature AS materialized
  USING (bucket, sensor_id)
WHERE ROW(raw.average_c, raw.minimum_c, raw.maximum_c, raw.reading_count)
      IS DISTINCT FROM
      ROW(materialized.average_c, materialized.minimum_c,
          materialized.maximum_c, materialized.reading_count);

SELECT ghw_cagg.assert_true(
    'continuous_aggregate_registered',
    EXISTS (SELECT 1 FROM timescaledb_information.continuous_aggregates
            WHERE view_schema = 'ghw_cagg'
              AND view_name = 'hourly_temperature' AND materialized_only),
    jsonb_build_object('materialized_only', true, 'bucket_width', '1 hour')
);
SELECT ghw_cagg.assert_true(
    'with_no_data_is_empty', count(*) = 0,
    jsonb_build_object('materialized_rows', count(*))
) FROM ghw_cagg.hourly_temperature;

CALL refresh_continuous_aggregate(
    'ghw_cagg.hourly_temperature',
    TIMESTAMPTZ '2026-10-01 00:00:00+00',
    TIMESTAMPTZ '2026-10-08 00:00:00+00'
);

SELECT ghw_cagg.assert_true(
    'initial_refresh_matches_raw', count(*) = 0,
    jsonb_build_object('mismatched_buckets', count(*))
) FROM ghw_cagg.mismatched_buckets;
SELECT ghw_cagg.assert_true(
    'hourly_cardinality_matches_raw',
    (SELECT count(*) FROM ghw_cagg.hourly_temperature) = count(*)
    AND count(*) = 336,
    jsonb_build_object('raw_groups', count(*),
                      'materialized_groups', (SELECT count(*) FROM ghw_cagg.hourly_temperature))
) FROM ghw_cagg.raw_hourly_truth;

-- Preserve real initial materialized values for the stale-data assertion.
CREATE TABLE ghw_cagg.initial_materialization AS
SELECT * FROM ghw_cagg.hourly_temperature;
TABLE timescaledb_information.continuous_aggregates;
SELECT * FROM ghw_cagg.hourly_temperature ORDER BY bucket, sensor_id LIMIT 8;

\echo PHASE 3: insert late data and correct an old reading
-- Both changes affect already-materialized historical buckets.
INSERT INTO ghw_cagg.readings VALUES ('2026-10-02 04:30:30+00', 1, 42.00);
DO $$
DECLARE affected integer;
BEGIN
    UPDATE ghw_cagg.readings SET temperature_c = 5.00
    WHERE observed_at = TIMESTAMPTZ '2026-10-05 10:15:00+00' AND sensor_id = 2;
    GET DIAGNOSTICS affected = ROW_COUNT;
    PERFORM ghw_cagg.assert_true(
        'historical_correction_updated_one_row', affected = 1,
        jsonb_build_object('updated_rows', affected)
    );
END
$$;

SELECT ghw_cagg.assert_true(
    'late_reading_present', count(*) = 20161,
    jsonb_build_object('actual_rows', count(*))
) FROM ghw_cagg.readings;
SELECT ghw_cagg.assert_true(
    'materialization_remains_unchanged_before_refresh', count(*) = 0,
    jsonb_build_object('changed_materialized_rows', count(*))
) FROM (
    (SELECT * FROM ghw_cagg.hourly_temperature
     EXCEPT SELECT * FROM ghw_cagg.initial_materialization)
    UNION ALL
    (SELECT * FROM ghw_cagg.initial_materialization
     EXCEPT SELECT * FROM ghw_cagg.hourly_temperature)
) AS differences;
SELECT ghw_cagg.assert_true(
    'late_data_and_correction_make_two_stale_buckets', count(*) = 2,
    jsonb_build_object('mismatched_buckets', count(*))
) FROM ghw_cagg.mismatched_buckets;

-- Save observed stale values before refreshing, so the proof remains inspectable.
CREATE TABLE ghw_cagg.stale_bucket_evidence AS
SELECT * FROM ghw_cagg.mismatched_buckets;
SELECT * FROM ghw_cagg.stale_bucket_evidence ORDER BY bucket, sensor_id;

\echo PHASE 4: refresh the invalidated history and recheck all aggregate fields
CALL refresh_continuous_aggregate(
    'ghw_cagg.hourly_temperature',
    TIMESTAMPTZ '2026-10-01 00:00:00+00',
    TIMESTAMPTZ '2026-10-08 00:00:00+00'
);
SELECT ghw_cagg.assert_true(
    'refresh_repairs_all_stale_buckets', count(*) = 0,
    jsonb_build_object('mismatched_buckets', count(*))
) FROM ghw_cagg.mismatched_buckets;
SELECT ghw_cagg.assert_true(
    'refresh_changes_only_two_affected_buckets', count(*) = 2,
    jsonb_build_object('changed_buckets', count(*))
) FROM (
    SELECT * FROM ghw_cagg.hourly_temperature
    EXCEPT SELECT * FROM ghw_cagg.initial_materialization
) AS changed;
SELECT actual.* FROM ghw_cagg.hourly_temperature AS actual
JOIN ghw_cagg.stale_bucket_evidence AS stale USING (bucket, sensor_id)
ORDER BY actual.bucket, actual.sensor_id;

\echo PHASE 5: configure and inspect a hourly refresh policy
-- Manual calls above prove refresh behavior. This policy is configured, not
-- claimed to have executed. The first run is deferred one hour to avoid races.
SELECT add_continuous_aggregate_policy(
    'ghw_cagg.hourly_temperature',
    start_offset => INTERVAL '30 days',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour',
    initial_start => clock_timestamp() + INTERVAL '1 hour'
);
SELECT ghw_cagg.assert_true(
    'refresh_policy_configured', count(*) = 1,
    jsonb_build_object('matching_scheduled_jobs', count(*))
) FROM timescaledb_information.jobs
WHERE hypertable_schema = 'ghw_cagg' AND hypertable_name = 'hourly_temperature'
  AND proc_name = 'policy_refresh_continuous_aggregate'
  AND scheduled AND schedule_interval = INTERVAL '1 hour';
SELECT job_id, proc_name, schedule_interval, scheduled, initial_start, config
FROM timescaledb_information.jobs
WHERE hypertable_schema = 'ghw_cagg' AND hypertable_name = 'hourly_temperature';

\echo PHASE 6: capture actual PostgreSQL query plans and timings
-- Identical seven-day window and result columns. EXPLAIN ANALYZE really runs
-- both queries; do not infer general speed guarantees from this small sample.
ANALYZE ghw_cagg.readings;
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SUMMARY)
SELECT time_bucket(INTERVAL '1 hour', observed_at) AS bucket,
       sensor_id, avg(temperature_c) AS average_c,
       min(temperature_c) AS minimum_c, max(temperature_c) AS maximum_c,
       count(*) AS reading_count
FROM ghw_cagg.readings
WHERE observed_at >= TIMESTAMPTZ '2026-10-01 00:00:00+00'
  AND observed_at < TIMESTAMPTZ '2026-10-08 00:00:00+00'
GROUP BY time_bucket(INTERVAL '1 hour', observed_at), sensor_id
ORDER BY bucket, sensor_id;
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SUMMARY)
SELECT bucket, sensor_id, average_c, minimum_c, maximum_c, reading_count
FROM ghw_cagg.hourly_temperature
WHERE bucket >= TIMESTAMPTZ '2026-10-01 00:00:00+00'
  AND bucket < TIMESTAMPTZ '2026-10-08 00:00:00+00'
ORDER BY bucket, sensor_id;

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

\echo OBSERVED DATABASE ASSERTIONS
SELECT test_name, passed, observed FROM ghw_cagg.checks ORDER BY checked_at, test_name;
SELECT count(*) AS assertions_passed FROM ghw_cagg.checks;
SELECT version() AS postgres_version;
SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';
