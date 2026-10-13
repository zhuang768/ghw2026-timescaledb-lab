# Continuous aggregates: real-time metrics and historical corrections

This lab runs genuine TimescaleDB SQL on a local PostgreSQL database. Its data is synthetic: two temperature sensors report once per minute over seven fixed UTC days. It does not use Tiger Cloud and does not claim a Cloud deployment.

`cagg.sql` creates a real hypertable containing 20,160 initial rows, then an hourly continuous aggregate with average, minimum, maximum, and count. The first six phases use `WITH NO DATA` and `timescaledb.materialized_only = true` to make the stored materialization behavior visible. A manual refresh produces 336 sensor/hour groups, which are compared with a fresh SQL aggregation of every raw row.

The script then inserts an out-of-order reading into an existing historical bucket and corrects another historical reading. It verifies that the raw table now has 20,161 rows, that the stored aggregate still equals its initial snapshot, and that exactly two buckets disagree with the raw truth. A second refresh removes every discrepancy across all four aggregate fields. The observed stale values are preserved in `ghw_cagg.stale_bucket_evidence`.

Phase 7 enables real-time aggregation with `timescaledb.materialized_only = false`. It inserts a new reading at `2026-10-08 00:10 UTC`, beyond the previous refresh watermark. Without any further refresh, the CAGG immediately returns the new hourly bucket with average, minimum, and maximum of 30°C and count 1. The script resolves the backing materialization hypertable through TimescaleDB metadata and directly verifies that it still stores **zero rows** for that bucket. A full comparison against raw SQL then finds zero discrepancies. The final dataset contains 20,162 readings and 337 hourly groups.

This distinguishes two useful behaviors: new data after the materialization watermark is available through the real-time tail, while changes to older, already-materialized history require a refresh.

An hourly refresh policy is registered with a 30-day start offset and a 1-hour end offset. Its first run is deferred one hour so it cannot invalidate the deterministic manual demonstration. Policy metadata proves configuration; this lab does not claim that the background job ran.

Run the script in a fresh, dedicated database with TimescaleDB installed and preloaded:

```sh
psql -X --set=ON_ERROR_STOP=1 --file=cagg.sql DATABASE_NAME
```

The script creates only its own `ghw_cagg` schema and the TimescaleDB extension if absent. It refuses to reuse an existing schema and never drops existing data. Use a new lab database for a repeat run.

Each assertion raises an error on failure and records its actual observed result in `ghw_cagg.checks`. The completed execution recorded **17/17 passing assertions**: 13 for the initial materialization, historical corrections, and policy, followed by four for real-time behavior. The first six phases are captured in [`evidence/cagg-output.txt`](evidence/cagg-output.txt), including the stale values, refreshed values, extension metadata, policy, and real query plans. Phase 7 was executed immediately afterward against the same database using [`real-time-tail.sql`](real-time-tail.sql), with its complete output in [`evidence/real-time-output.txt`](evidence/real-time-output.txt). The standalone file contains exactly the same phase 7 SQL now included in `cagg.sql` for a fresh full run.

The run used **PostgreSQL 17.7** on macOS arm64 and **TimescaleDB 2.22.1**. It verified 20,160 initial readings, 20,161 readings after the late insertion, 336 materialized hourly groups, two stale buckets before the second refresh, zero mismatched buckets afterward, and the immediately visible real-time tail.

Before enabling real-time mode, phase 6 executes two real `EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SUMMARY)` queries over the same seven-day window: one recomputes the raw aggregation; the other reads the continuous aggregate. Captured execution times were **3.574 ms** for raw aggregation and **0.085 ms** for the materialized query. Both returned 336 rows. These are measurements of one small local run; caching and workload size affect results, so they do not establish a general performance guarantee.

Official API references:

- [Create a continuous aggregate](https://docs.tigerdata.com/use-timescale/latest/continuous-aggregates/create-a-continuous-aggregate/)
- [Refresh a continuous aggregate](https://www.tigerdata.com/docs/reference/timescaledb/continuous-aggregates/refresh_continuous_aggregate)
- [Add a refresh policy](https://www.tigerdata.com/docs/reference/timescaledb/continuous-aggregates/add_continuous_aggregate_policy)

The installed TimescaleDB 2.22.1 source also defines these APIs in `sql/ddl_api.sql` and `sql/policy_api.sql`; its own regression tests use `timescaledb.materialized_only = true` for explicit materialization checks.
