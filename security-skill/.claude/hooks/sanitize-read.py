#!/usr/bin/env python3
"""
PreToolUse hook for the Read tool.
Scans file content for prompt injection patterns before Claude sees it.
Exit 1 to block, exit 0 to allow.
"""
import sys
import json
import os
import re

INJECTION_PATTERNS = [
    r"ignore\s+(previous|prior|all)\s+instructions",
    r"you\s+are\s+now\s+a",
    r"new\s+system\s+prompt",
    r"disregard\s+(all|prior|previous)",
    r"forget\s+(your|all\s+previous)\s+instructions",
    r"override\s+(your\s+)?(previous\s+)?instructions",
    r"assistant\s*:\s*i\s+will\s+now",
    r"<\s*system\s*>",
]

try:
    inp = json.loads(os.environ.get("CLAUDE_TOOL_INPUT", "{}"))
except json.JSONDecodeError:
    sys.exit(0)

path = inp.get("file_path", "")
if not path:
    sys.exit(0)

# Only scan text files — skip binaries
try:
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read(50_000)  # scan first 50KB
except (OSError, PermissionError):
    sys.exit(0)  # unreadable = let Read tool handle the error

for pat in INJECTION_PATTERNS:
    if re.search(pat, content, re.IGNORECASE):
        print(
            f"[security hook] BLOCKED: prompt injection pattern detected in: {path}\n"
            f"  Pattern: {pat}\n"
            f"  Snippet: {re.search(pat, content, re.IGNORECASE).group()!r}",
            file=sys.stderr,
        )
        sys.exit(1)

sys.exit(0)
