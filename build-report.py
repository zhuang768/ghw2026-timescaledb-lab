#!/usr/bin/env python3
"""Render a static evidence page from an actual database snapshot and SQL logs."""
import html
import json
from pathlib import Path

root = Path(__file__).resolve().parent
result = json.loads((root / "evidence/results.json").read_text())
cagg = result["cagg"]
checks = cagg["checks"]
assert len(checks) == 17 and all(c["passed"] for c in checks)
assert cagg["mismatches_after_refresh"] == 0 and cagg["real_time_enabled"]
tail = cagg["real_time_tail"]
rows = "".join(
    f'<tr><td>{html.escape(c["name"].replace("_", " "))}</td>'
    f'<td class="pass">PASS</td><td><code>{html.escape(json.dumps(c["observed"], sort_keys=True))}</code></td></tr>'
    for c in checks
)
logs = "".join(
    f'<details><summary>{html.escape(label)}</summary><pre>{html.escape((root / path).read_text())}</pre></details>'
    for label, path in [
        ("Actual CAGG SQL output — first 13 checks and measured query plans", "evidence/cagg-output.txt"),
        ("Actual real-time tail SQL output — four additional checks", "evidence/real-time-output.txt"),
        ("Database environment read-back", "evidence/environment.txt"),
        ("Official source archive SHA-256 hashes", "evidence/source-hashes.txt"),
    ]
)
page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>GHW 2026 · Real TimescaleDB continuous aggregate evidence</title>
<style>
*{{box-sizing:border-box}}body{{margin:0;background:#f2f5f3;color:#183429;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}main{{max-width:1180px;margin:auto;padding:42px 30px}}h1{{font-size:36px;line-height:1.15;letter-spacing:-1px;margin:12px 0}}h2{{font-size:25px;margin:0 0 12px}}p{{margin:10px 0}}.eyebrow{{font-size:13px;letter-spacing:2px;font-weight:700;text-transform:uppercase}}.scope{{color:#52655d;max-width:960px}}.stamp{{display:inline-block;padding:6px 12px;background:#d8eddf;color:#155234;border-radius:5px;font-size:14px;font-weight:700}}.grid{{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:25px 0}}.metric,.card{{background:#fff;border:1px solid #d6e1d9;border-radius:10px;padding:18px}}.metric strong{{display:block;font-size:30px;line-height:1.3}}.metric span{{font-size:13px;color:#596c62}}.card{{margin:16px 0;padding:24px}}.flow{{display:grid;grid-template-columns:1fr 1fr;gap:22px}}code,pre{{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}}code{{font-size:12px;overflow-wrap:anywhere}}pre{{font-size:12px;white-space:pre-wrap;overflow-wrap:anywhere;background:#f5f7f5;padding:14px;border-radius:6px}}table{{width:100%;border-collapse:collapse;font-size:14px}}th,td{{text-align:left;border-bottom:1px solid #e0e7e2;padding:9px 10px;vertical-align:top}}th{{color:#597163;font-weight:600}}.pass{{color:#147540;font-weight:700;white-space:nowrap}}.small{{font-size:13px;color:#596c62}}a{{color:#176047}}details{{margin:12px 0}}summary{{cursor:pointer;font-weight:600}}@media(max-width:760px){{.grid{{grid-template-columns:1fr 1fr}}.flow{{grid-template-columns:1fr}}h1{{font-size:29px}}main{{padding:25px 15px}}td:first-child{{max-width:145px}}}}
</style></head><body><main>
<div class="eyebrow">Global Hack Week 2026 · Executed SQL evidence</div>
<h1>Continuous aggregates with a verified real-time tail</h1>
<span class="stamp">17 / 17 database assertions passed</span>
<p class="scope">Actual isolated, self-hosted PostgreSQL {result["postgresql_version"]} + TimescaleDB {result["extensions"]["timescaledb"]}. Synthetic temperature readings; SQL prepared with Codex and executed in the real database. No Tiger Cloud or Copilot claim.</p>
<p class="small">Database snapshot: {html.escape(result["captured_at_utc"])} · TCP disabled · TimescaleDB telemetry off</p>
<div class="grid"><div class="metric"><strong>{cagg["raw_rows"]:,}</strong><span>Final raw sensor readings</span></div><div class="metric"><strong>{cagg["hourly_groups"]}</strong><span>Hourly sensor groups</span></div><div class="metric"><strong>2 → 0</strong><span>Stale buckets after refresh</span></div><div class="metric"><strong>0 stored</strong><span>New tail bucket visible through real-time SQL</span></div></div>
<section class="card"><h2>What the database proved</h2><div class="flow"><div><strong>Historical data and explicit refresh</strong><p>Two sensors × seven days produced 20,160 original rows and 336 hourly groups. A late reading and an old correction left exactly two materialized buckets stale. Refresh repaired both; average, minimum, maximum and count all matched raw SQL truth.</p></div><div><strong>Fresh data beyond the watermark</strong><p>Real-time mode enabled with <code>materialized_only=false</code>. A new reading at 2026-10-08 00:10 UTC appeared without another refresh: average/min/max {tail["average_c"]:g} °C, count {tail["reading_count"]}. The actual backing materialization still contained zero rows for that bucket.</p></div></div><p class="small">An hourly refresh policy is configured with a 30-day start offset and 1-hour end offset. Background policy execution is not claimed. Late historical data still needs refresh; the raw real-time tail handles data newer than the watermark.</p></section>
<section class="card"><h2>Measured query plans</h2><p>Before the real-time tail phase, both queries returned the same 336 rows over the same seven-day window. Actual <code>EXPLAIN (ANALYZE, BUFFERS)</code> execution times: raw aggregation <strong>3.574 ms</strong>; materialized CAGG read <strong>0.085 ms</strong>.</p><p class="small">One small local run with warm-cache effects; these observations are not a general speed guarantee or a benchmark of the final real-time union.</p></section>
<section class="card"><h2>Observed assertions</h2><table><thead><tr><th>Check</th><th>Result</th><th>Database observation</th></tr></thead><tbody>{rows}</tbody></table></section>
<section class="card"><h2>Reproduce and inspect</h2><p><a href="cagg.sql">Full CAGG SQL</a> · <a href="CAGG.md">Detailed explanation</a> · <a href="evidence/results.json">Actual JSON snapshot</a> · <a href="README.md">Build and run instructions</a></p>{logs}</section>
<p class="small">This page is a static rendering of captured database results. It does not simulate the database or assert event acceptance.</p>
</main></body></html>'''
(root / "report.html").write_text(page)
print("Generated report.html from 17 actual passing checks.")
