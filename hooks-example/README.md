# process_refund — Tool + Hook Template

Working example of an MCP tool with PreToolUse and PostToolUse hooks.

## File Map

```
hooks-example/
├── README.md                          ← you are here
├── .mcp.json                          ← registers the MCP server with Claude Code
├── .claude/
│   ├── settings.json                  ← wires hooks to the tool name
│   └── hooks/
│       ├── pre_process_refund.py      ← PreToolUse: blocks >$500, normalises input
│       ├── post_process_refund.py     ← PostToolUse: audits, enriches result
│       └── audit.log                  ← written by both hooks at runtime (gitignore)
└── mcp_tools/
    └── refund_server.py               ← MCP server defining process_refund tool
```

### Cross-references

| File | References |
|------|-----------|
| `.mcp.json` | → `mcp_tools/refund_server.py` (command to start server) |
| `.claude/settings.json` | → `hooks/pre_process_refund.py`, `hooks/post_process_refund.py` |
| `pre_process_refund.py` | reads env: `REFUND_APPROVAL_THRESHOLD`, `REFUND_AUDIT_LOG` |
| `post_process_refund.py` | reads env: `REFUND_AUDIT_LOG` |
| `refund_server.py` | reads env: `REFUND_API_KEY` (injected from `.mcp.json`) |

---

## How It Works

```
User prompt
    │
    ▼
Claude decides to call process_refund(customer_id, order_id, amount, reason)
    │
    ▼ ── PreToolUse hook fires ──────────────────────────────────────────────
    │   .claude/hooks/pre_process_refund.py receives tool_input on stdin
    │   ┌─ amount > $500? → exit 2, stderr = error message → Claude sees error,
    │   │                    tool never runs, no retry loops generated
    │   └─ amount <= $500 → normalise IDs → print {"tool_input": ...} → exit 0
    │
    ▼ ── Tool executes ──────────────────────────────────────────────────────
    │   mcp_tools/refund_server.py:process_refund() runs
    │   Returns: {"status": "success", "transaction_id": "TXN-...", ...}
    │         or {"status": "error", "errorCategory": "transient", "isRetryable": true, ...}
    │
    ▼ ── PostToolUse hook fires ─────────────────────────────────────────────
    │   .claude/hooks/post_process_refund.py receives tool_input + tool_result on stdin
    │   → writes audit.log entry
    │   → enriches result with isRetryable, errorCategory, agentHint
    │   → prints {"tool_result": "...enriched JSON string..."} → exit 0
    │
    ▼
Claude receives enriched result and decides next action
```

---

## Setup (6 steps)

### Step 1 — Install the MCP package

```bash
pip install mcp
```

### Step 2 — Set environment variables

```bash
export REFUND_API_KEY="your-api-key-here"
export REFUND_APPROVAL_THRESHOLD=500   # optional, default $500
export REFUND_AUDIT_LOG=".claude/hooks/audit.log"  # optional
```

Add these to your shell profile or a `.env` file (do not commit `.env`).

### Step 3 — Verify the MCP server starts

```bash
cd hooks-example
python3 mcp_tools/refund_server.py
# Should start without errors (waits for MCP messages on stdio)
# Ctrl-C to stop
```

### Step 4 — Open Claude Code in this directory

```bash
cd hooks-example
claude
```

Claude Code reads `.mcp.json` on startup, launches `refund_server.py` as a subprocess, and registers `mcp__refund-tools__process_refund` as an available tool.

### Step 5 — Verify hooks are active (Claude Code console)

```
/hooks
```

You should see `pre_process_refund.py` and `post_process_refund.py` listed under the tool name.

### Step 6 — Test it

Try these prompts inside Claude Code:

```
Process a refund of $150 for customer CUST-456, order ORD-789.
Reason: product arrived damaged.
```
→ Should succeed. Check `audit.log` for the entry.

```
Process a refund of $750 for customer CUST-123, order ORD-321.
```
→ Should be **blocked** by the PreToolUse hook.
Claude sees: "Refund of $750.00 exceeds the $500 autonomous limit. Manager approval required."

---

## Key Concepts

### Tool name format for MCP tools

```
mcp__<server-name>__<tool-name>
```

The server name comes from the key in `.mcp.json` (`"refund-tools"`).
The tool name comes from the function name in the MCP server (`process_refund`).
Dashes in the server name are preserved.

So: `mcp__refund-tools__process_refund`

Use this exact string as the `matcher` in `.claude/settings.json`.

### PreToolUse — exit codes

| Exit | Effect |
|------|--------|
| `0` with empty stdout | Allow, pass input unchanged |
| `0` with `{"tool_input": {...}}` on stdout | Allow, with modified input |
| `2` | **Block** — stderr message returned to Claude as the tool error |
| `1` or other | Hook error (logged, tool call blocked) |

### PostToolUse — stdout

| Stdout | Effect |
|--------|--------|
| Empty | Tool result passed to Claude unchanged |
| `{"tool_result": "..."}` | Claude sees this string instead of the real result |

### Structured error responses (from refund_server.py)

Always return these fields on error so hooks and Claude can route correctly:

```python
{
    "status":        "error",
    "errorCategory": "transient" | "validation" | "permission" | "business",
    "isRetryable":   True | False,
    "message":       "human-readable explanation"
}
```

`isRetryable: False` is the key field that prevents Claude from retrying fraud blocks
and compliance rejections in a loop (which would generate duplicate audit alerts).

---

## Adapting to a new tool

1. Copy `mcp_tools/refund_server.py` → add your `@mcp.tool()` function
2. Copy `pre_process_refund.py` → update the business rules section
3. Copy `post_process_refund.py` → update the enrichment section
4. In `.mcp.json` add your server under `mcpServers`
5. In `.claude/settings.json` add matchers under `PreToolUse` / `PostToolUse`
   - matcher = `mcp__<your-server-name>__<your-tool-name>`
6. Update env var names and audit log path as needed

---

## What NOT to do

| Anti-pattern | Why it fails |
|--------------|-------------|
| Enforce amount cap via system prompt | Non-zero failure rate; logs show 3% violations |
| Return `{"status":"success", "results":[]}` on network timeout | Prevents coordinator recovery; report is missing data with no signal |
| Return same error string for all failure types | Agent retries fraud blocks, generates compliance alerts |
| Hardcode `REFUND_API_KEY` in `.mcp.json` | Commits secret to version control |
| Skip `isRetryable` field | Agent defaults to retrying everything |
