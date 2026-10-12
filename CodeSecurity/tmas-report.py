
#!/usr/bin/env python3
"""Convert TMAS JSON to a console summary and an optional static HTML dashboard."""
import argparse
import html
import json
from pathlib import Path

SEVERITIES = [
    ("Critical", "criticalCount", "#ee4055"),
    ("High", "highCount", "#f28a30"),
    ("Medium", "mediumCount", "#e5c34b"),
    ("Low", "lowCount", "#589dce"),
    ("Unknown", "unknownCount", "#9699a4"),
]


def esc(value):
    return html.escape(str(value), quote=True)


def integer(value):
    try:
        return int(value or 0)
    except (ValueError, TypeError):
        return 0


def fixes_for(item):
    vals = []
    for key in ("fix", "fixedVersion", "fixedVersions", "fixVersions", "allFixedVersions", "availableFixVersions"):
        val = item.get(key)
        if isinstance(val, str):
            vals.extend(x.strip() for x in val.split(","))
        elif isinstance(val, list):
            for entry in val:
                if isinstance(entry, dict):
                    v = entry.get("version") or entry.get("fixedVersion")
                    if v:
                        vals.append(str(v))
                elif entry is not None:
                    vals.append(str(entry))
    return list(dict.fromkeys(x for x in vals if x and x.lower() not in
                              {"not-fixed", "none", "n/a", "unknown", "-"}))


def findings_for(v):
    findings = v.get("findings") or {}
    if isinstance(findings, dict):
        sources = [(severity, record) for severity, records in findings.items()
                   if isinstance(records, list) for record in records]
    elif isinstance(findings, list):
        sources = [(record.get("severity", "Unknown"), record) for record in findings
                   if isinstance(record, dict)]
    else:
        sources = []
    rows = []
    for sev, item in sources:
        if not isinstance(item, dict):
            continue
        fixes = fixes_for(item)
        raw_fix = item.get("fix")
        status = ("Available" if fixes else "Not available" if
                  isinstance(raw_fix, str) and raw_fix.lower() == "not-fixed" else "Not reported")
        rows.append({"severity": str(sev), "cve": str(item.get("id", "N/A")),
                     "package": str(item.get("name", "N/A")),
                     "installed": str(item.get("version", "N/A")),
                     "fix": ", ".join(fixes) if fixes else status,
                     "status": status, "has_fix": bool(fixes)})
    order = {"Critical": 0, "High": 1, "Medium": 2, "Low": 3, "Negligible": 4, "Unknown": 5}
    rows.sort(key=lambda r: (not r["has_fix"], order.get(r["severity"], 9), r["package"], r["cve"]))
    return rows


def generate_report(d, exit_code, outdir):
    v = d.get("vulnerabilities") or {}
    p = d.get("policyEvaluation") or {}
    policy = p.get("policyEvaluated") or {}
    artifact = d.get("artifactMetadata") or {}
    secrets = d.get("secrets") or {}
    counts = [(s, integer(v.get(key)), color) for s, key, color in SEVERITIES]
    highest = max([count for _, count, _ in counts] + [1])
    rows = findings_for(v)
    available = sum(r["has_fix"] for r in rows)
    decision = str(p.get("result", "Unknown"))
    gate = "PASSED" if exit_code == 0 else "BLOCKED" if exit_code == 2 else "SCAN ERROR"
    print("\n===== TRENDAI SECURITY REPORT =====")
    print("Image:", artifact.get("artifactID", "N/A"))
    for sev, count, _ in counts:
        print(f"{sev}: {count}")
    print("Total:", integer(v.get("totalVulnCount")))
    print("Policy:", policy.get("name", "N/A"))
    print("Decision:", decision)
    print("Fixes available:", available, "of", len(rows), "findings")
    print("Security Gate:", gate, f"(exit {exit_code})")

    css = """body{background:#090909;color:#eee;font:14px Arial,sans-serif;margin:0;padding:24px}
main{max-width:1200px;margin:auto;border:1px solid #333;border-radius:14px;padding:28px}
h1{font-size:27px;margin:8px 0}h2{font-size:18px;margin:28px 0 18px}
.muted,small{color:#aaa}.eyebrow{font-size:12px;color:#aaa;font-weight:bold}
.top{display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap}
.metrics,.summary{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:14px;margin:24px 0}
.metric,.card{background:#181818;border-radius:10px;padding:18px;text-align:center}
.metric b{display:block;font-size:32px}.metric span{color:#aaa}
.bar{display:grid;grid-template-columns:85px 1fr 45px;align-items:center;gap:12px;margin:12px 0}
.track{height:12px;background:#292929;overflow:hidden;border-radius:12px}
.fill{height:100%;border-radius:12px}.bar strong{text-align:right}
section{border-top:1px solid #292929;margin-top:24px;padding-top:8px}
.rule{display:flex;justify-content:space-between;gap:15px;padding:14px 0;border-bottom:1px solid #292929}
.rule small{display:block;margin-top:5px}.pill{padding:6px 12px;border-radius:20px;background:#333;font-size:12px;font-weight:bold}
.pill.block,.blocked{color:#ff8585}.pill.log{color:#ffae61}.passed,.available{color:#65d78f}
.error,.unavailable{color:#ff8585}.unknown{color:#aaa}
.card small{display:block}.card strong{display:block;margin-top:8px;overflow-wrap:anywhere}
.scroll{max-height:650px;overflow:auto;border:1px solid #333;border-radius:9px}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{padding:12px;text-align:left;border-bottom:1px solid #333;vertical-align:top}
th{background:#202020;position:sticky;top:0}td{overflow-wrap:anywhere}
.sev-Critical{color:#ee4055}.sev-High{color:#f28a30}.sev-Medium{color:#e5c34b}
.sev-Low{color:#589dce}.meta{overflow-wrap:anywhere}
"""
    bars = ""
    for i, (severity, count, color) in enumerate(counts):
        css += f".bar-{i}{{width:{100*count/highest:.2f}%;background-color:{color}}}\n"
        css += f".metric-{i}{{color:{color}}}\n"
        bars += (f'<div class="bar"><span>{esc(severity)}</span><div class="track">'
                 f'<div class="fill bar-{i}"></div></div><strong>{count}</strong></div>')

    rules = []
    for key, action in (("logPolicyViolations", "LOG"), ("blockPolicyViolations", "BLOCK")):
        for category, matches in (p.get(key) or {}).items():
            if not isinstance(matches, list):
                continue
            for match in matches:
                if not isinstance(match, dict):
                    continue
                rule = match.get("rule") or {}
                rules.append(f'<div class="rule"><div><strong>{esc(rule.get("ruleDescription",category))}'
                             f'</strong><small>{esc(match.get("numOfViolations",0))} rule matches</small></div>'
                             f'<span class="pill {action.lower()}">{action}</span></div>')
    rules_html = "".join(rules) or "<p>No matching policy rules.</p>"

    table_rows = "".join(
        f'<tr><td class="sev-{esc(r["severity"])}">{esc(r["severity"])}</td>'
        f'<td>{esc(r["cve"])}</td><td>{esc(r["package"])}</td>'
        f'<td>{esc(r["installed"])}</td><td>{esc(r["fix"])}</td>'
        f'<td class="{("available" if r["has_fix"] else "unavailable")}">{esc(r["status"])}</td></tr>'
        for r in rows
    ) or '<tr><td colspan="6">No findings in the report.</td></tr>'

    severity_cards = "".join(f'<div class="metric"><b class="metric-{i}">{count}</b><span>{esc(sev)}</span></div>'
                             for i, (sev, count, _) in enumerate(counts[:2]))
    css_path = outdir / "tmas-report.css"
    html_path = outdir / "tmas-report.html"
    css_path.write_text(css, encoding="utf-8")
    report = f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>TrendAI Security Report</title><link rel="stylesheet" href="tmas-report.css"></head>
<body><main><div class="top"><div><div class="eyebrow">TRENDAI / CONTAINER SECURITY</div>
<h1>Image Security Assessment</h1><p class="muted meta">{esc(artifact.get("artifactID","N/A"))} · {esc(policy.get("name","N/A"))} v{esc(policy.get("version","N/A"))}</p>
</div><span class="pill {"block" if exit_code == 2 else "log"}">{esc(gate)}</span></div>
<div class="metrics">{severity_cards}<div class="metric"><b>{integer(secrets.get("unmitigatedFindingsCount"))}</b><span>Secrets</span></div>
<div class="metric"><b>{integer(v.get("totalVulnCount"))}</b><span>Total vulnerabilities</span></div></div>
<section><h2>Vulnerabilities by Severity</h2>{bars}</section>
<section><h2>Security Gate Result</h2><div class="summary">
<div class="card"><small>Gate Status</small><strong>{esc(gate)}</strong></div>
<div class="card"><small>Policy Decision</small><strong>{esc(decision)}</strong></div>
<div class="card"><small>TMAS Exit Code</small><strong>{exit_code}</strong></div></div></section>
<section><h2>Policy Enforcement</h2>{rules_html}<p class="muted">Rule matches may overlap.</p></section>
<section><h2>Available Fixes</h2><p>{available} findings with reported fixes · {len(rows)} findings total</p>
<div class="scroll"><table><thead><tr><th>Severity</th><th>CVE</th><th>Package</th>
<th>Installed version</th><th>Fix reported by TMAS</th><th>Status</th></tr></thead><tbody>{table_rows}</tbody></table></div></section>
</main></body></html>'''
    html_path.write_text(report, encoding="utf-8")
    print("HTML dashboard:", html_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default="tmas-results.json")
    ap.add_argument("--html", action="store_true", help="Generate HTML and CSS")
    ap.add_argument("--exit-code", type=int, default=0, help="TMAS exit code, only for display")
    args = ap.parse_args()
    path = Path(args.input)
    d = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(d, dict) or not isinstance(d.get("vulnerabilities"), dict):
        raise ValueError("TMAS JSON is missing vulnerabilities object")
    if args.html:
        generate_report(d, args.exit_code, path.parent)
    else:
        v = d.get("vulnerabilities") or {}
        p = d.get("policyEvaluation") or {}
        print("TMAS Summary | Critical:", v.get("criticalCount", 0),
              "High:", v.get("highCount", 0),
              "Policy:", p.get("result", "Unknown"),
              "Exit:", args.exit_code)


if __name__ == "__main__":
    main()
