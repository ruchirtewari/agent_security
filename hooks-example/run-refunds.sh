#!/usr/bin/env bash
# run-refunds.sh — end-to-end batch refund test
#
# STEP 1  Verify all hook/tool files exist (pip install mcp separately if needed)
# STEP 2  Generate test-refunds.json covering all error paths
# STEP 3  Run each case through Claude CLI (pre-hook → tool → post-hook → trace)
# STEP 4  Analyze audit.log + stream-json traces → print stats
#
# Usage:  cd hooks-example && bash run-refunds.sh
#         (no env vars required — test key is hardcoded below for the demo)
#
# Prerequisites: pip install mcp   (one-time; not done here)
#
# Error paths exercised:
#   TC-01  success — standard ($150)
#   TC-02  success — edge case at $499.99
#   TC-03  pre-hook block — $500.01 (just over threshold)
#   TC-04  pre-hook block — $1200 (large amount)
#   TC-05  validation error — negative amount
#   TC-06  validation error — zero amount
#   TC-07  transient error — order_id ends with FAIL (simulated outage)
#   TC-08  permission error — REFUND_API_KEY explicitly unset

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ── Colors ─────────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'
info() { echo -e "${C}▸${N} $*"; }
ok()   { echo -e "${G}✓${N} $*"; }
warn() { echo -e "${Y}!${N} $*"; }
bail() { echo -e "${R}✗${N} $*" >&2; exit 1; }
hdr()  { echo -e "\n${B}════ $* ════${N}"; }

# ══════════════════════════════════════════════════════════════════════════════
hdr "STEP 1 — Verify"

# mcp must already be installed (pip install mcp) — not done here
#python3 -c "import mcp" 2>/dev/null \
# && ok "mcp package found" \
# || bail "mcp not installed — run: pip install mcp"

REQUIRED=(
  mcp_tools/refund_server.py
  .mcp.json
  .claude/settings.json
  .claude/hooks/pre_process_refund.py
  .claude/hooks/post_process_refund.py
)
for f in "${REQUIRED[@]}"; do
  [[ -f "$f" ]] && ok "$f" || bail "Missing required file: $f"
done

command -v claude  &>/dev/null || bail "claude CLI not found — npm install -g @anthropic-ai/claude-code"
command -v python3 &>/dev/null || bail "python3 not found"
ok "claude: $(claude --version 2>/dev/null | head -1 || echo found)"

# Use caller-supplied key or fall back to a test sentinel.
# TC-08 will override this to "" to exercise the missing-key path.
export REFUND_API_KEY="${REFUND_API_KEY:-test-key-demo-123}"
ok "REFUND_API_KEY=${REFUND_API_KEY}"

mkdir -p traces .claude/hooks
AUDIT_LOG=".claude/hooks/audit.log"
> "$AUDIT_LOG"
ok "audit.log reset"

# ══════════════════════════════════════════════════════════════════════════════
hdr "STEP 2 — Generate test data (test-refunds.json)"

cat > test-refunds.json << 'TESTDATA'
[
  {
    "id": "TC-01",
    "description": "success — standard refund below threshold",
    "customer_id": "CUST-001",
    "order_id": "ORD-1001",
    "amount": 150.00,
    "reason": "Product arrived damaged — packaging crushed",
    "expected": "success"
  },
  {
    "id": "TC-02",
    "description": "success — edge case $499.99 (one cent under $500 limit)",
    "customer_id": "CUST-002",
    "order_id": "ORD-1002",
    "amount": 499.99,
    "reason": "Wrong item shipped, customer kept original",
    "expected": "success"
  },
  {
    "id": "TC-03",
    "description": "pre-hook block — $500.01 (one cent over threshold)",
    "customer_id": "CUST-003",
    "order_id": "ORD-1003",
    "amount": 500.01,
    "reason": "Full order return, all items unopened",
    "expected": "pre_hook_blocked"
  },
  {
    "id": "TC-04",
    "description": "pre-hook block — $1200 (subscription cancellation)",
    "customer_id": "CUST-004",
    "order_id": "ORD-1004",
    "amount": 1200.00,
    "reason": "Annual subscription cancelled within 30-day window",
    "expected": "pre_hook_blocked"
  },
  {
    "id": "TC-05",
    "description": "validation error — negative amount (-$50)",
    "customer_id": "CUST-005",
    "order_id": "ORD-1005",
    "amount": -50.00,
    "reason": "Negative amount to test input validation",
    "expected": "validation_error"
  },
  {
    "id": "TC-06",
    "description": "validation error — zero amount ($0.00)",
    "customer_id": "CUST-006",
    "order_id": "ORD-1006",
    "amount": 0.00,
    "reason": "Zero amount to test boundary validation",
    "expected": "validation_error"
  },
  {
    "id": "TC-07",
    "description": "transient error — order_id ends in FAIL (simulated payment processor outage)",
    "customer_id": "CUST-007",
    "order_id": "ORD-1007-FAIL",
    "amount": 75.00,
    "reason": "Defective battery, safety return required",
    "expected": "transient_error"
  },
  {
    "id": "TC-08",
    "description": "permission error — REFUND_API_KEY explicitly unset for this call",
    "customer_id": "CUST-008",
    "order_id": "ORD-1008",
    "amount": 200.00,
    "reason": "Testing missing API key path",
    "expected": "permission_error",
    "env_override": {"REFUND_API_KEY": ""}
  }
]
TESTDATA

N=$(python3 -c "import json; print(len(json.load(open('test-refunds.json'))))")
ok "Written test-refunds.json — $N test cases"
echo ""
python3 -c "
import json
cases = json.load(open('test-refunds.json'))
print('  {:6}  {:22}  {:>10}  {}'.format('ID','Expected','Amount','Description'))
print('  ' + '─'*72)
for tc in cases:
    print('  {:6}  {:22}  \${:>9.2f}  {}'.format(
        tc['id'], tc['expected'], tc['amount'], tc['description'][:45]))
"

# ══════════════════════════════════════════════════════════════════════════════
hdr "STEP 3 — Run refunds through Claude (non-interactive)"

info "Flow per case: claude -p → PreToolUse hook → MCP tool → PostToolUse hook → trace saved"
echo ""

python3 << 'PYEOF'
import json, os, subprocess, sys, re
from pathlib import Path

TEST_FILE  = Path("test-refunds.json")
TRACES_DIR = Path("traces")
test_cases = json.loads(TEST_FILE.read_text())
parent_env = dict(os.environ)

FAIL = "\033[0;31m✗\033[0m"
PASS = "\033[0;32m✓\033[0m"
WARN = "\033[1;33m!\033[0m"

def sniff_outcome(text):
    """Best-effort outcome detection from raw trace text."""
    if "transaction_id" in text and '"success"' in text:
        return "success", PASS
    if "exceeds" in text and "limit" in text:
        return "pre_hook_blocked", WARN
    if "autonomous limit" in text or "Manager approval" in text:
        return "pre_hook_blocked", WARN
    m = re.search(r'errorCategory[\\"\s:]+(\w+)', text)
    if m:
        cat = m.group(1)
        return f"error:{cat}", WARN
    if "timeout" in text:
        return "timeout", FAIL
    if '"error"' in text or "ERROR" in text:
        return "error:unknown", WARN
    return "unknown", "?"

errors = []
for tc in test_cases:
    tc_id   = tc["id"]
    cid     = tc["customer_id"]
    oid     = tc["order_id"]
    amt     = tc["amount"]
    reason  = tc["reason"]
    env_ovr = tc.get("env_override", {})

    prompt = (
        f'Call the process_refund tool with exactly these parameters — do not modify them. '
        f'Report the complete raw JSON result you receive. '
        f'customer_id: "{cid}", order_id: "{oid}", amount: {amt}, reason: "{reason}"'
    )

    env = {**parent_env, **env_ovr}
    trace_path = TRACES_DIR / f"{tc_id}.jsonl"

    print(f"  {tc_id}  ${amt:>9.2f}  {tc['expected']:<22}", end="  ", flush=True)

    try:
        result = subprocess.run(
            [
                "claude", "--print", "--verbose", prompt,
                "--output-format", "stream-json",
                "--setting-sources", "project",
                "--mcp-config", ".mcp.json", "--strict-mcp-config",
                "--allowedTools", "mcp__refund-tools__process_refund",
            ],
            capture_output=True, text=True, timeout=90, env=env
        )
        trace_path.write_text(result.stdout)
        if result.stderr:
            with open(trace_path, "a") as f:
                f.write(result.stderr)
    except subprocess.TimeoutExpired:
        trace_path.write_text('{"error":"timeout after 90s"}')
        print(f"{FAIL} TIMEOUT")
        errors.append(tc_id)
        continue
    except FileNotFoundError:
        print(f"{FAIL} claude not found")
        sys.exit(1)

    outcome, icon = sniff_outcome(trace_path.read_text())
    print(f"{icon} {outcome}")

if errors:
    print(f"\n  Timed out: {', '.join(errors)}")
else:
    print(f"\n  All {len(test_cases)} test cases complete.")
PYEOF

ok "Traces saved to traces/TC-*.jsonl"

# ══════════════════════════════════════════════════════════════════════════════
hdr "STEP 4 — Analyze audit log + traces"

python3 << 'PYEOF'
import json, re
from pathlib import Path
from collections import defaultdict

TRACES_DIR = Path("traces")
AUDIT_LOG  = Path(".claude/hooks/audit.log")
TEST_FILE  = Path("test-refunds.json")

test_cases = json.loads(TEST_FILE.read_text())
N = len(test_cases)

# ── Parse audit log ──────────────────────────────────────────────────────────
pre_calls   = 0
pre_blocked = 0
pre_allowed = 0
post_records = []

if AUDIT_LOG.exists():
    for raw in AUDIT_LOG.read_text().splitlines():
        line = raw.strip()
        if not line:
            continue
        if " PRE  " in line:
            pre_calls += 1
            if "BLOCKED" in line:
                pre_blocked += 1
            else:
                pre_allowed += 1
        else:
            try:
                rec = json.loads(line)
                if isinstance(rec, dict) and rec.get("hook") == "post":
                    post_records.append(rec)
            except json.JSONDecodeError:
                pass

# ── Parse traces ─────────────────────────────────────────────────────────────
tool_calls_total = 0
trace_outcomes   = {}
error_cats_trace = defaultdict(int)

def count_tool_calls(text):
    """Count process_refund tool_use events in stream-json trace."""
    count = 0
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        # stream-json: tool_use nested inside assistant message content list
        if ev.get("type") == "assistant":
            for block in ev.get("message", {}).get("content", []):
                if block.get("type") == "tool_use" and "process_refund" in block.get("name", ""):
                    count += 1
        # flat tool_use event
        elif ev.get("type") == "tool_use" and "process_refund" in ev.get("name", ""):
            count += 1
    # Fallback: count occurrences if JSON parsing yielded nothing
    if count == 0 and "process_refund" in text:
        count = text.count('"process_refund"')
    return count

def sniff_outcome(text):
    if "transaction_id" in text and '"success"' in text:
        return "success"
    if "exceeds" in text and "limit" in text:
        return "pre_hook_blocked"
    if "autonomous limit" in text or "Manager approval" in text:
        return "pre_hook_blocked"
    m = re.search(r'errorCategory[\\"\s:]+(\w+)', text)
    if m:
        return f"error:{m.group(1)}"
    if "timeout" in text:
        return "timeout"
    if '"error"' in text or '"status": "error"' in text:
        return "error:unknown"
    return "unknown"

for tc in test_cases:
    trace_file = TRACES_DIR / f"{tc['id']}.jsonl"
    if not trace_file.exists():
        trace_outcomes[tc["id"]] = "no_trace"
        continue
    text = trace_file.read_text()
    calls = count_tool_calls(text)
    tool_calls_total += calls
    outcome = sniff_outcome(text)
    trace_outcomes[tc["id"]] = outcome
    if outcome.startswith("error:"):
        cat = outcome.split(":")[1]
        if cat not in ("unknown",):
            error_cats_trace[cat] += 1

# ── Verdict ──────────────────────────────────────────────────────────────────
def verdict(expected, actual):
    mapping = {
        "success":          lambda a: a == "success",
        "pre_hook_blocked": lambda a: a == "pre_hook_blocked",
        "validation_error": lambda a: "validation" in a,
        "transient_error":  lambda a: "transient"  in a,
        "permission_error": lambda a: "permission" in a,
    }
    check = mapping.get(expected, lambda a: False)
    if check(actual):   return "\033[0;32m✓ PASS\033[0m"
    if actual == "unknown": return "\033[1;33m? UNK\033[0m"
    return "\033[0;31m✗ FAIL\033[0m"

# ── Post-hook breakdown ───────────────────────────────────────────────────────
post_success = sum(1 for r in post_records if r.get("status") == "success")
post_error   = sum(1 for r in post_records if r.get("status") == "error")
post_cats    = defaultdict(int)
for r in post_records:
    if r.get("category"):
        post_cats[r["category"]] += 1

# ── Report ────────────────────────────────────────────────────────────────────
SEP = "─" * 62
print(f"\n{SEP}")
print("  REFUND BATCH TEST — SUMMARY REPORT")
print(SEP)
print(f"  Total test cases run        : {N}")
print(f"  Tool calls detected         : {tool_calls_total}")
print()

print("  PRE-HOOK  (pre_process_refund.py)")
print(f"    Total invocations         : {pre_calls}")
print(f"    Allowed through           : {pre_allowed}")
print(f"    Blocked (exit 2)          : {pre_blocked}")
if pre_calls == 0:
    print("    (0 invocations → check REFUND_API_KEY and claude auth)")
print()

print("  POST-HOOK  (post_process_refund.py)")
print(f"    Total invocations         : {len(post_records)}")
print(f"    Success records           : {post_success}")
print(f"    Error records             : {post_error}")
if post_cats:
    for cat, cnt in sorted(post_cats.items()):
        print(f"    error/{cat:<14}  : {cnt}")
print()

print("  ERROR CATEGORIES  (from traces)")
if error_cats_trace:
    for cat, cnt in sorted(error_cats_trace.items()):
        print(f"    {cat:<18}    : {cnt}")
else:
    print("    (none parsed from traces — check traces/*.jsonl directly)")
print()

print("  PER-TEST RESULTS")
print(f"  {'ID':6}  {'Expected':22}  {'Actual outcome':30}  {'Result':12}")
print(f"  {'─'*6}  {'─'*22}  {'─'*30}  {'─'*12}")
counts = {"pass": 0, "fail": 0, "unk": 0}
for tc in test_cases:
    tid = tc["id"]
    exp = tc["expected"]
    act = trace_outcomes.get(tid, "no_trace")
    v   = verdict(exp, act)
    if   "PASS" in v: counts["pass"] += 1
    elif "UNK"  in v: counts["unk"]  += 1
    else:             counts["fail"] += 1
    print(f"  {tid:6}  {exp:22}  {act:30}  {v}")
print()
print(f"  Passed: {counts['pass']}  Failed: {counts['fail']}  Unknown: {counts['unk']}")
print()
print("  Files")
print(f"    Audit log   : .claude/hooks/audit.log")
print(f"    Trace files : traces/TC-*.jsonl")
print()
print("  Debug tips")
print("    cat traces/TC-07.jsonl | python3 -m json.tool 2>/dev/null | head -60")
print("    grep 'errorCategory' traces/*.jsonl")
print("    tail -20 .claude/hooks/audit.log")
print(SEP)
PYEOF
