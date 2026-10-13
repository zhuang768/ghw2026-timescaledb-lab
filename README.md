# GHW 2026 — self-hosted TimescaleDB lab

This is an actual SQL lab executed on an isolated local PostgreSQL 17.7 database with TimescaleDB 2.22.1. The source SQL and build/run scripts were prepared with Codex, then executed against the real database. This project does not claim GitHub Copilot authorship or a Tiger Cloud deployment.

The database was built from pinned official source releases in a dedicated directory. It accepts only a private local Unix socket, has TCP listening disabled, and has TimescaleDB telemetry disabled. No remote database, new persistent password, paid service, or private dataset was used.

## Continuous aggregate

`cagg.sql` creates a Timescale hypertable with two synthetic temperature sensors reporting every minute for seven UTC days. The hourly continuous aggregate computes average, minimum, maximum, and count. Historical late-data and correction checks compare the materialized results with a fresh raw SQL aggregation, then explicitly refresh and verify every affected bucket.

See [CAGG.md](CAGG.md) for the final observed counts, real-time tail proof, policy configuration, and the measured query plans. The policy is configured; its background execution is not claimed. Small single-run timings are observations, not a general performance guarantee.

## Evidence and reproduction

- [report.html](report.html): static readable view generated from actual SQL output and a database snapshot.
- [evidence/results.json](evidence/results.json): actual CAGG database snapshot, 17 check results, and the real-time tail bucket.
- [evidence/cagg-output.txt](evidence/cagg-output.txt): complete CAGG `psql` output.
- [evidence/environment.txt](evidence/environment.txt): database versions and isolation settings.
- [evidence/source-hashes.txt](evidence/source-hashes.txt): measured SHA-256 hashes of the source archives. PostgreSQL's archive also matched its official published checksum.

To reproduce in a fresh dedicated directory, with a compiler, make, Python 3, tar and OpenSSL/zlib development headers already available:

```bash
bash build-local.sh
bash run-local.sh
python3 serve-local.py --psql runtime/bin/psql --socket "${TMPDIR:-/tmp}/ghw2026-timescale-lab"
# After viewing the dashboard, stop the server with Ctrl-C, then stop PostgreSQL:
runtime/bin/pg_ctl -D db-data stop
```

`cagg.sql` intentionally refuses to reuse its existing schema. Repeat the full demonstration in a new database; the scripts do not delete prior database data. The actual run used macOS arm64 and Apple Clang 17.0.0. Source builds on another platform need that platform's ordinary PostgreSQL build dependencies.

Official source releases:

- [PostgreSQL 17.7](https://ftp.postgresql.org/pub/source/v17.7/)
- [TimescaleDB 2.22.1](https://github.com/timescale/timescaledb/tree/2.22.1)
- [pgvector 0.8.1](https://github.com/pgvector/pgvector/tree/v0.8.1)

The publication contains SQL, scripts, documentation and sanitized query evidence only. Build products, database storage, private server logs and downloaded source trees are excluded.

The local dashboard binds only `127.0.0.1:8789`. Each refresh runs one fixed, read-only SQL query through the database's private Unix socket and displays the query timestamp, versions, aggregate metrics and persisted assertions. Its routes expose only the dashboard, live status and recorded report; it accepts no SQL from HTTP clients. `report.html` is clearly labeled as recorded evidence.
