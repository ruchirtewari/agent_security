#!/usr/bin/env python3
"""
PreToolUse hook for the Bash tool.
Blocks dangerous command patterns before Claude executes them.
Exit 1 = blocked. Exit 0 = allowed.
"""
import sys
import json
import os
import re

try:
    inp = json.loads(os.environ.get("CLAUDE_TOOL_INPUT", "{}"))
except json.JSONDecodeError:
    sys.exit(0)

cmd = inp.get("command", "")
if not cmd:
    sys.exit(0)

# Always blocked — no exceptions
DENYLIST = [
    (r"rm\s+-rf\s+[/~*]",               "destructive rm -rf on root/home/glob"),
    (r"rm\s+--no-preserve-root",         "rm --no-preserve-root"),
    (r"sudo\s+rm",                        "sudo rm"),
    (r"curl[^\n]+\|\s*(bash|sh|zsh)",    "remote code execution via curl|shell"),
    (r"wget[^\n]+\|\s*(bash|sh|zsh)",    "remote code execution via wget|shell"),
    (r"chmod\s+[0-9]*7[0-9]*\s+/",      "world-writable chmod on system path"),
    (r":\(\)\{.*\|.*&.*\}",              "fork bomb"),
    (r"dd\s+if=.*of=/dev/(sd|hd|nvme)",  "dd to raw disk device"),
    (r">\s*/dev/sd[a-z]",               "direct write to block device"),
    (r"mkfs\.",                          "filesystem format command"),
    (r"git\s+push\s+(-f|--force)\s+.*\bmain\b|\bmaster\b",
                                         "force push to main/master"),
]

# Sensitive paths — block any command that reads/writes these
SENSITIVE_PATHS = [
    "/etc/passwd", "/etc/shadow", "/etc/sudoers",
    os.path.expanduser("~/.ssh/id_"),
    os.path.expanduser("~/.aws/credentials"),
    os.path.expanduser("~/.gnupg/"),
]

for pattern, reason in DENYLIST:
    if re.search(pattern, cmd, re.IGNORECASE | re.DOTALL):
        print(f"[security hook] BLOCKED: {reason}", file=sys.stderr)
        print(f"  Command: {cmd[:120]!r}", file=sys.stderr)
        sys.exit(1)

for path in SENSITIVE_PATHS:
    if path in cmd:
        print(f"[security hook] BLOCKED: access to sensitive path: {path}", file=sys.stderr)
        sys.exit(1)

sys.exit(0)
