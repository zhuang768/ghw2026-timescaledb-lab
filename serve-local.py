#!/usr/bin/env python3
"""Loopback-only dashboard with one fixed, read-only PostgreSQL query.

After build-local.sh and run-local.sh, with the database running in this directory:
  python3 serve-local.py
No SQL, filenames, database settings, or commands are accepted over HTTP.
"""

import argparse
import json
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


PUBLIC_DIR = Path(__file__).resolve().parent
STATUS_SQL = """
SELECT jsonb_build_object(
  'queried_at_utc', to_char(clock_timestamp() AT TIME ZONE 'UTC',
                          'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
  'postgresql_version', current_setting('server_version'),
  'transaction_read_only', current_setting('transaction_read_only'),
  'extensions', (SELECT jsonb_object_agg(extname, extversion)
                 FROM pg_extension WHERE extname IN ('timescaledb', 'vector')),
  'materialized_only', (SELECT materialized_only
    FROM timescaledb_information.continuous_aggregates
    WHERE view_schema = 'ghw_cagg' AND view_name = 'hourly_temperature'),
  'real_time_enabled', (SELECT NOT materialized_only
    FROM timescaledb_information.continuous_aggregates
    WHERE view_schema = 'ghw_cagg' AND view_name = 'hourly_temperature'),
  'checks_total', (SELECT count(*) FROM ghw_cagg.checks),
  'checks_passed', (SELECT count(*) FROM ghw_cagg.checks WHERE passed),
  'checks', (SELECT jsonb_agg(jsonb_build_object('name', test_name,
                    'passed', passed) ORDER BY checked_at, test_name)
             FROM ghw_cagg.checks),
  'raw_rows', (SELECT count(*) FROM ghw_cagg.readings),
  'hourly_groups', (SELECT count(*) FROM ghw_cagg.hourly_temperature),
  'mismatched_buckets', (SELECT count(*) FROM ghw_cagg.mismatched_buckets),
  'latest_bucket', (SELECT to_jsonb(t) FROM (
    SELECT bucket, sensor_id, average_c, minimum_c, maximum_c, reading_count
    FROM ghw_cagg.hourly_temperature ORDER BY bucket DESC, sensor_id LIMIT 1
  ) AS t),
  'refresh_policy_configured', EXISTS (
    SELECT 1 FROM timescaledb_information.jobs
    WHERE hypertable_schema = 'ghw_cagg' AND hypertable_name = 'hourly_temperature'
      AND proc_name = 'policy_refresh_continuous_aggregate' AND scheduled),
  'recorded_tail_materialization_proof', (SELECT observed
    FROM ghw_cagg.checks WHERE test_name = 'real_time_tail_is_not_materialized')
);
"""


def read_status(args):
    # Use a minimal environment; do not inherit credentials or read .pgpass.
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'PGPASSFILE': '/dev/null',
           'PGOPTIONS': '-c default_transaction_read_only=on -c statement_timeout=7000'}
    result = subprocess.run(
        [str(args.psql), '-X', '-A', '-t', '-w', '--set=ON_ERROR_STOP=1',
         '--host', args.socket, '--port', str(args.db_port),
         '--username', args.user, '--dbname', args.database,
         '--command', STATUS_SQL],
        check=True, capture_output=True, text=True, timeout=10, env=env,
        cwd=PUBLIC_DIR,
    )
    status = json.loads(result.stdout.strip())
    if not isinstance(status, dict):
        raise ValueError('Unexpected query response')
    return status


def make_handler(args):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'GHWLocalLab/1.0'
        sys_version = ''

        def respond(self, code, body, content_type):
            self.send_response(code)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Security-Policy',
                "default-src 'self'; script-src 'self' 'unsafe-inline'; "
                "style-src 'self' 'unsafe-inline'; connect-src 'self'; "
                "base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            parsed = urlsplit(self.path)
            host = urlsplit('//' + self.headers.get('Host', '')).hostname
            if host not in ('127.0.0.1', 'localhost'):
                self.respond(403, b'Loopback host required.', 'text/plain; charset=utf-8')
                return
            if parsed.query or parsed.fragment:
                self.respond(400, b'Query parameters are not supported.', 'text/plain; charset=utf-8')
                return
            if parsed.path == '/api/status':
                try:
                    payload = json.dumps(read_status(args), ensure_ascii=False).encode('utf-8')
                except (subprocess.SubprocessError, OSError, ValueError):
                    # Never expose connection paths, credentials, or subprocess stderr.
                    payload = json.dumps({'error': 'Live SQL query is unavailable. Check the local database.'}).encode()
                    self.respond(503, payload, 'application/json; charset=utf-8')
                    return
                self.respond(200, payload, 'application/json; charset=utf-8')
                return
            # Explicit public-file allowlist; no filesystem path is taken from HTTP.
            routes = {
                '/': ('dashboard.html', 'text/html; charset=utf-8'),
                '/report.html': ('report.html', 'text/html; charset=utf-8'),
                '/README.md': ('README.md', 'text/plain; charset=utf-8'),
                '/CAGG.md': ('CAGG.md', 'text/plain; charset=utf-8'),
                '/cagg.sql': ('cagg.sql', 'text/plain; charset=utf-8'),
                '/real-time-tail.sql': ('real-time-tail.sql', 'text/plain; charset=utf-8'),
                '/snapshot.sql': ('snapshot.sql', 'text/plain; charset=utf-8'),
                '/build-local.sh': ('build-local.sh', 'text/plain; charset=utf-8'),
                '/run-local.sh': ('run-local.sh', 'text/plain; charset=utf-8'),
                '/build-report.py': ('build-report.py', 'text/plain; charset=utf-8'),
                '/serve-local.py': ('serve-local.py', 'text/plain; charset=utf-8'),
                '/dashboard.html': ('dashboard.html', 'text/html; charset=utf-8'),
                '/evidence/results.json': ('evidence/results.json', 'application/json; charset=utf-8'),
                '/evidence/database-snapshot.json': ('evidence/database-snapshot.json', 'application/json; charset=utf-8'),
                '/evidence/cagg-output.txt': ('evidence/cagg-output.txt', 'text/plain; charset=utf-8'),
                '/evidence/real-time-output.txt': ('evidence/real-time-output.txt', 'text/plain; charset=utf-8'),
                '/evidence/environment.txt': ('evidence/environment.txt', 'text/plain; charset=utf-8'),
                '/evidence/source-hashes.txt': ('evidence/source-hashes.txt', 'text/plain; charset=utf-8'),
            }
            entry = routes.get(parsed.path)
            if entry is None:
                self.respond(404, b'Not found.', 'text/plain; charset=utf-8')
                return
            target = PUBLIC_DIR / entry[0]
            try:
                body = target.read_bytes()
            except OSError:
                self.respond(404, b'Report unavailable.', 'text/plain; charset=utf-8')
                return
            self.respond(200, body, entry[1])

        def do_POST(self):
            self.respond(405, b'Read-only dashboard.', 'text/plain; charset=utf-8')

        do_PUT = do_POST
        do_PATCH = do_POST
        do_DELETE = do_POST

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    local_psql = PUBLIC_DIR / 'runtime' / 'bin' / 'psql'
    parser.add_argument('--psql', type=Path,
                        default=local_psql if local_psql.is_file()
                        else PUBLIC_DIR.parent / 'runtime' / 'bin' / 'psql')
    parser.add_argument('--socket', default=str(Path(tempfile.gettempdir()) / 'ghw2026-timescale-lab'))
    parser.add_argument('--port', type=int, default=8789)
    parser.add_argument('--db-port', type=int, default=55473)
    parser.add_argument('--user', default='ghw_lab')
    parser.add_argument('--database', default='ghw_lab')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not 1 <= args.db_port <= 65535:
        parser.error('Ports must be between 1 and 65535.')
    if not Path(args.socket).is_absolute():
        parser.error('--socket must be an absolute Unix socket directory.')
    server = ThreadingHTTPServer(('127.0.0.1', args.port), make_handler(args))
    print(f'Live read-only dashboard: http://127.0.0.1:{args.port}/', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
