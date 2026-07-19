"""
PostToolUse hook: process_refund
Fires AFTER the MCP tool returns. Can audit, enrich, or replace the result.

Wired by:   ../.claude/settings.json  (hooks.PostToolUse matcher)
Tool code:  ../../mcp_tools/refund_server.py
Pre hook:   ./pre_process_refund.py
README:     ../../README.md

── Stdin (JSON) ──────────────────────────────────────────────────────────────
{
  "session_id":  "abc123",
  "tool_name":   "mcp__refund-tools__process_refund",
  "tool_input":  { "customer_id": "CUST-456", "order_id": "ORD-789",
                   "amount": 150.00, "reason": "Product defective" },
  "tool_result": "{\"status\":\"success\",\"transaction_id\":\"TXN-ORD-789-01500000\",...}"
}

── Exit codes ────────────────────────────────────────────────────────────────
  0    Pass through (optionally with modified result on stdout)
  (non-zero causes the hook to error — avoid unless intentional)

── Stdout (optional) ─────────────────────────────────────────────────────────
  {"tool_result": "...string..."}   Replace result Claude sees
  (empty)                           Pass result through unchanged
"""

import json
import os
import sys
from datetime import datetime

AUDIT_LOG = os.environ.get("REFUND_AUDIT_LOG", ".claude/hooks/audit.log")


def log(record: dict) -> None:
    ts = datetime.utcnow().isoformat()
    try:
        with open(AUDIT_LOG, "a") as f:
            f.write(json.dumps({"ts": ts, "hook": "post", **record}) + "\n")
    except OSError:
        pass


def unwrap_tool_response(resp):
    """Reduce any tool_response shape to the tool's own JSON payload as a dict."""
    if isinstance(resp, dict) and "content" in resp:
        resp = resp["content"]
    if isinstance(resp, list):
        resp = "\n".join(
            b.get("text", "") for b in resp
            if isinstance(b, dict) and b.get("type") == "text"
        )
    if isinstance(resp, str):
        try:
            return json.loads(resp)
        except json.JSONDecodeError:
            return {"raw": resp}
    return resp if isinstance(resp, dict) else {"raw": resp}


def main() -> None:
    # ── 1. Parse stdin ────────────────────────────────────────────────────────
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"post_process_refund: could not parse stdin: {e}", file=sys.stderr)
        sys.exit(0)

    session_id  = data.get("session_id", "unknown")
    tool_input  = data.get("tool_input", {})
    # Claude Code sends the result under "tool_response"; older docs said "tool_result"
    raw_result  = data.get("tool_response", data.get("tool_result", ""))

    # ── 2. Parse the tool result ─────────────────────────────────────────────
    # MCP tools arrive wrapped: {"content":[{"type":"text","text":"<json>"}], "isError": false}
    # Unwrap the envelope, then parse the inner JSON string.
    result = unwrap_tool_response(raw_result)

    # ── 3. Audit log every call ───────────────────────────────────────────────
    log({
        "session":    session_id,
        "customer":   tool_input.get("customer_id"),
        "order":      tool_input.get("order_id"),
        "amount":     tool_input.get("amount"),
        "status":     result.get("status"),
        "txn":        result.get("transaction_id"),
        "retryable":  result.get("isRetryable"),
        "category":   result.get("errorCategory"),
    })

    # ── 4. Enrich the result Claude sees ─────────────────────────────────────
    # Add structured fields that help Claude decide next steps
    if result.get("status") == "error":
        enriched = {
            **result,
            # Ensure these fields are always present so Claude can branch correctly
            "isRetryable":   result.get("isRetryable", False),
            "errorCategory": result.get("errorCategory", "unknown"),
            # Add a hint for the agent so it doesn't have to infer retry logic
            "agentHint": (
                "Retry after a short delay."
                if result.get("isRetryable")
                else "Do not retry. Inform the customer and escalate if needed."
            ),
        }
    else:
        enriched = {
            **result,
            # Confirm to the agent it succeeded and memory should be updated
            "agentHint": "Refund successful. Record the transaction_id for the customer.",
        }

    # ── 5. Output enriched result ─────────────────────────────────────────────
    # Output must be the full replacement string (not a dict) to match tool_result type
    print(json.dumps({"tool_result": json.dumps(enriched)}))
    sys.exit(0)


if __name__ == "__main__":
    main()
