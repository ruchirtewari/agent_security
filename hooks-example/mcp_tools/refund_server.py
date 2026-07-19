"""
MCP server: refund-tools
Registers process_refund as an MCP tool available to Claude Code.

Referenced by:  ../.mcp.json          (how Claude discovers this server)
Hook coverage:  ../.claude/settings.json (Pre/PostToolUse on process_refund)
Pre hook:       ../.claude/hooks/pre_process_refund.py
Post hook:      ../.claude/hooks/post_process_refund.py
Install:        pip install mcp
Run directly:   python3 refund_server.py (MCP over stdio)
"""

import json
import os
import sys
from datetime import datetime

try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    print("ERROR: mcp package not installed. Run: pip install mcp", file=sys.stderr)
    sys.exit(1)

mcp = FastMCP("refund-tools")


@mcp.tool()
def process_refund(
    customer_id: str,
    order_id: str,
    amount: float,
    reason: str,
) -> dict:
    """Process a customer refund.

    Refunds <= $500 execute automatically.
    Refunds >  $500 are blocked by the PreToolUse hook and require manager approval.

    Args:
        customer_id: Customer identifier (e.g. CUST-123)
        order_id:    Order identifier (e.g. ORD-456)
        amount:      Refund amount in USD (must be > 0)
        reason:      Human-readable reason for the refund

    Returns:
        On success: { status, transaction_id, amount_refunded, customer_id, timestamp }
        On error:   { status, errorCategory, isRetryable, message }

    errorCategory values:
        validation  - bad input, don't retry
        transient   - network/db error, retry is safe
        business    - policy block, don't retry
        permission  - auth failure, don't retry
    """
    # --- Input validation -------------------------------------------------
    if not customer_id or not customer_id.strip():
        return {
            "status": "error",
            "errorCategory": "validation",
            "isRetryable": False,
            "message": "customer_id is required",
        }

    if not order_id or not order_id.strip():
        return {
            "status": "error",
            "errorCategory": "validation",
            "isRetryable": False,
            "message": "order_id is required",
        }

    if amount <= 0:
        return {
            "status": "error",
            "errorCategory": "validation",
            "isRetryable": False,
            "message": f"amount must be positive, got {amount}",
        }

    # --- Simulate API call ------------------------------------------------
    # In production: call your refund API here.
    # The PreToolUse hook already blocked amounts > $500 before we get here.
    api_key = os.environ.get("REFUND_API_KEY", "")
    if not api_key:
        return {
            "status": "error",
            "errorCategory": "permission",
            "isRetryable": False,
            "message": "REFUND_API_KEY env var not set — configure in .mcp.json",
        }

    # Simulate occasional transient failure for demo purposes
    # (remove this block in production)
    if order_id.endswith("FAIL"):
        return {
            "status": "error",
            "errorCategory": "transient",
            "isRetryable": True,
            "message": "Payment processor temporarily unavailable",
        }

    transaction_id = f"TXN-{order_id}-{int(amount * 100):08d}"
    return {
        "status": "success",
        "transaction_id": transaction_id,
        "amount_refunded": round(amount, 2),
        "customer_id": customer_id,
        "order_id": order_id,
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "message": f"Refund of ${amount:.2f} processed for order {order_id}",
    }


if __name__ == "__main__":
    mcp.run()
