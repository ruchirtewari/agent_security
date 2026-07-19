"""
PreToolUse hook: process_refund
Fires BEFORE the MCP tool executes. Can block or modify the call.

Wired by:   ../.claude/settings.json  (hooks.PreToolUse matcher)
Tool code:  ../../mcp_tools/refund_server.py
Post hook:  ./post_process_refund.py
README:     ../../README.md

── Stdin (JSON) ──────────────────────────────────────────────────────────────
{
  "session_id": "abc123",
  "tool_name":  "mcp__refund-tools__process_refund",
  "tool_input": {
    "customer_id": "CUST-456",
    "order_id":    "ORD-789",
    "amount":      600.00,
    "reason":      "Product defective"
  }
}

── Exit codes ────────────────────────────────────────────────────────────────
  0           Allow the call (unchanged or with modified tool_input on stdout)
  2           Block the call. Stderr message is returned to Claude as a tool error.

── Stdout (optional, exit 0 only) ───────────────────────────────────────────
  {"tool_input": {...}}   Override the input before the tool runs (e.g., normalise fields)
  (empty)                 Pass through unchanged
"""

import json
import os
import sys
from datetime import datetime

APPROVAL_THRESHOLD = float(os.environ.get("REFUND_APPROVAL_THRESHOLD", "500"))
AUDIT_LOG = os.environ.get("REFUND_AUDIT_LOG", ".claude/hooks/audit.log")


def log(msg: str) -> None:
    ts = datetime.utcnow().isoformat()
    try:
        with open(AUDIT_LOG, "a") as f:
            f.write(f"{ts} PRE  {msg}\n")
    except OSError:
        pass  # audit log write failure must never block the agent


def main() -> None:
    # ── 1. Parse stdin ────────────────────────────────────────────────────────
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        # Malformed input from harness — let it through, don't block
        print(f"pre_process_refund: could not parse stdin: {e}", file=sys.stderr)
        sys.exit(0)

    tool_input = data.get("tool_input", {})
    session_id = data.get("session_id", "unknown")
    amount     = float(tool_input.get("amount", 0))
    customer   = tool_input.get("customer_id", "")
    order      = tool_input.get("order_id", "")

    log(f"session={session_id} customer={customer} order={order} amount={amount}")

    # ── 2. Business rule: amount cap ─────────────────────────────────────────
    if amount > APPROVAL_THRESHOLD:
        msg = (
            f"Refund of ${amount:.2f} exceeds the ${APPROVAL_THRESHOLD:.0f} autonomous limit. "
            f"Manager approval is required before this refund can be processed. "
            f"Use the escalate_to_human tool to request approval."
        )
        log(f"BLOCKED amount={amount} exceeds threshold={APPROVAL_THRESHOLD}")
        print(msg, file=sys.stderr)
        sys.exit(2)  # 2 = block; stderr message becomes the tool error Claude sees

    # ── 3. Input normalisation (optional — strip whitespace, upper-case IDs) ─
    normalised_input = {
        **tool_input,
        "customer_id": customer.strip().upper(),
        "order_id":    order.strip().upper(),
        "amount":      round(amount, 2),
    }

    if normalised_input != tool_input:
        log(f"normalised input: {json.dumps(normalised_input)}")
        # Output modified input — Claude Code replaces the tool call args with this
        print(json.dumps({"tool_input": normalised_input}))

    # ── 4. Allow ─────────────────────────────────────────────────────────────
    sys.exit(0)


if __name__ == "__main__":
    main()
