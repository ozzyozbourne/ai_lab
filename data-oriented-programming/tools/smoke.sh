#!/usr/bin/env bash
# smoke.sh: open every book page headless at 1280 px and 375 px and report
#   - console errors and uncaught page errors (console warnings are listed but do not fail)
#   - every [data-viz] whose state is not "mounted" (error / unknown / never mounted), except ones marked
#     data-expect="error|unknown" (deliberate failure demos in components.html)
#   - [data-viz] showing a "no data yet" box (listed, not a failure)
#   - horizontal overflow (page wider than the viewport)
# Passes: 1280 px, 375 px, and 375 px with prefers-reduced-motion (figures must render their still frame).
#
#   tools/smoke.sh                       # every *.html in the book folder
#   tools/smoke.sh index.html 03-*.html  # some pages
#   OFFLINE=1 tools/smoke.sh index.html  # same, with cdn.jsdelivr.net blocked
#
# Uses agent-browser in its own session (AGENT_BROWSER_SESSION, default dod-smoke-<pid>). Exits 1 on any failure.
set -uo pipefail
BOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BOOK"
export AGENT_BROWSER_SESSION="${AGENT_BROWSER_SESSION:-dod-smoke-$$}"
AB=(agent-browser)

PAGES=("$@")
if [ ${#PAGES[@]} -eq 0 ]; then
	mapfile -t PAGES < <(ls -1 *.html 2>/dev/null)
fi
[ ${#PAGES[@]} -gt 0 ] || { echo "smoke.sh: no pages"; exit 1; }

if [ "${OFFLINE:-0}" = "1" ]; then
	"${AB[@]}" open about:blank >/dev/null
	"${AB[@]}" network route "**cdn.jsdelivr.net**" --abort >/dev/null
	echo "(cdn.jsdelivr.net blocked)"
fi

# Scrolls through the page so lazy figures mount, waits, then reports figure states and overflow.
read -r -d '' PROBE <<'EOF'
(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  await sleep(150);
  const H = () => document.documentElement.scrollHeight;
  for (let y = 0; y < H(); y += Math.max(200, innerHeight * 0.8)) { scrollTo(0, y); await sleep(60); }
  scrollTo(0, H()); await sleep(500); scrollTo(0, 0); await sleep(100);
  const figs = [...document.querySelectorAll("[data-viz]")].map((el, i) => ({
    i, name: el.dataset.viz, state: el.dataset.vizState || "not mounted", expect: el.dataset.expect || "",
    empty: el.dataset.vizEmpty === "1", msg: (el.querySelector(".viz-error, .viz-unknown, .viz-empty") || {}).textContent || "" }));
  return JSON.stringify({ book: typeof window.Book === "object" && !!window.Book.viz, figs,
    overflow: document.documentElement.scrollWidth - innerWidth, title: document.title });
})()
EOF

FAILS=0
printf '%-44s %-5s %-6s %s\n' page pass result details
for page in "${PAGES[@]}"; do
	[ -f "$page" ] || { printf '%-44s %-5s %-6s %s\n' "$page" "-" FAIL "missing file"; FAILS=1; continue; }
	for pass in 1280 375 375rm; do
		width="${pass%rm}"
		"${AB[@]}" open about:blank >/dev/null 2>&1
		if [ "$pass" = "375rm" ]; then "${AB[@]}" set media dark reduced-motion >/dev/null 2>&1; else "${AB[@]}" set media dark >/dev/null 2>&1; fi
		"${AB[@]}" console --clear >/dev/null 2>&1
		"${AB[@]}" errors --clear >/dev/null 2>&1
		"${AB[@]}" set viewport "$width" 800 >/dev/null 2>&1
		"${AB[@]}" open "file://$BOOK/$page" >/dev/null 2>&1
		"${AB[@]}" wait --load load >/dev/null 2>&1
		probe="$(printf '%s' "$PROBE" | "${AB[@]}" eval --stdin 2>&1 | tail -n 1)"
		console="$("${AB[@]}" console --json 2>/dev/null)"
		errors="$("${AB[@]}" errors --json 2>/dev/null)"
		out="$(python3 - "$probe" "$console" "$errors" <<'PY'
import json, sys
probe, console, errors = sys.argv[1:4]
bad, notes = [], []
try:
    p = json.loads(probe)
    if isinstance(p, str): p = json.loads(p)
except Exception as e:
    print("FAIL\tprobe failed: " + probe[:200]); sys.exit()
if not p.get("book"): bad.append("window.Book missing")
for f in p["figs"]:
    if f["expect"]:
        if f["state"] != f["expect"]: bad.append("figure #%d %s expected %s, got %s" % (f["i"], f["name"], f["expect"], f["state"]))
        continue
    if f["state"] != "mounted": bad.append("figure #%d %s: %s %s" % (f["i"], f["name"], f["state"], f["msg"][:120]))
    elif f["empty"]: notes.append("no data: %s" % f["name"])
if p["overflow"] > 1: bad.append("horizontal overflow %d px" % p["overflow"])
def msgs(s, key):
    try: return json.loads(s)["data"][key] or []
    except Exception: return []
for m in msgs(console, "messages"):
    t = m.get("type")
    if t == "error": bad.append("console error: " + m.get("text", "")[:200])
    elif t in ("warning", "warn"): notes.append("console warning: " + m.get("text", "")[:160])
for e in msgs(errors, "errors"):
    bad.append("page error: " + (e.get("message") or e.get("text") or json.dumps(e))[:200])
n = len(p["figs"])
print(("FAIL" if bad else "ok") + "\t" + "; ".join(["%d figures" % n] + bad + notes))
PY
)"
		res="${out%%$'\t'*}"; det="${out#*$'\t'}"
		[ "$res" = "ok" ] || FAILS=1
		printf '%-44s %-5s %-6s %s\n' "$page" "$pass" "$res" "$det"
	done
done
"${AB[@]}" close >/dev/null 2>&1
if [ $FAILS -ne 0 ]; then echo "smoke.sh: FAILURES"; exit 1; fi
echo "smoke.sh: all pages ok"
