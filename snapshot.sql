\set ON_ERROR_STOP on
SELECT jsonb_build_object(
  'captured_at_utc', to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'postgresql_version', current_setting('server_version'),
  'extensions', (SELECT jsonb_object_agg(extname, extversion) FROM pg_extension WHERE extname IN ('timescaledb','vector')),
  'execution_scope', 'isolated self-hosted database; no Tiger Cloud service',
  'tcp_listening_disabled', current_setting('listen_addresses') = '',
  'timescaledb_telemetry', current_setting('timescaledb.telemetry_level'),
  'cagg', jsonb_build_object(
    'raw_rows', (SELECT count(*) FROM ghw_cagg.readings),
    'hourly_groups', (SELECT count(*) FROM ghw_cagg.hourly_temperature),
    'stale_buckets_before_refresh', (SELECT count(*) FROM ghw_cagg.stale_bucket_evidence),
    'mismatches_after_refresh', (SELECT count(*) FROM ghw_cagg.mismatched_buckets),
    'real_time_enabled', EXISTS (SELECT 1 FROM timescaledb_information.continuous_aggregates WHERE view_schema='ghw_cagg' AND view_name='hourly_temperature' AND NOT materialized_only),
    'real_time_tail', (SELECT to_jsonb(t) FROM (SELECT bucket, sensor_id, average_c, minimum_c, maximum_c, reading_count FROM ghw_cagg.hourly_temperature WHERE bucket=TIMESTAMPTZ '2026-10-08 00:00:00+00' AND sensor_id=1) t),
    'checks', (SELECT jsonb_agg(jsonb_build_object('name', test_name, 'passed', passed, 'observed', observed) ORDER BY checked_at) FROM ghw_cagg.checks),
    'hourly_refresh_policy_configured', EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE hypertable_schema='ghw_cagg' AND hypertable_name='hourly_temperature' AND proc_name='policy_refresh_continuous_aggregate' AND schedule_interval=INTERVAL '1 hour')
  )
);
