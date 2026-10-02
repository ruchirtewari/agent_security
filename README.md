# agent_security

Working examples of harness-level security controls for Claude Code agents.

## Purpose

This examples show how to implement security boundaries for Claude with hooks, permissions and skills. 
A system prompt that says "never refund more than $500" or "never run `rm -rf`" has a non-zero failure
rate. The examples in this directory show how to move those rules out of the
prompt and into the harness, where they are enforced deterministically by
code that runs before and after every tool call.

Comparison of the approaches

| Mechanism | What it gives you |
|-----------|-------------------|
| **Hooks** (`PreToolUse` / `PostToolUse`) | Block, rewrite, or annotate a tool call with a script that Claude cannot bypass |
| **Permissions** (`allow` / `deny` lists) | Auto-approve safe commands, hard-block dangerous ones, prompt for everything else |
| **Skills and commands** | Package a repeatable security review or workflow as a `/slash-command` |

## Scope

In scope:

- Claude Code CLI projects (interactive and `-p` non-interactive runs)
- MCP tools you write yourself and want to guard with business rules
- Prompt-injection defence for file reads, shell output, and web results
- Destructive-command blocking (`rm -rf`, `curl | bash`, force push, raw disk writes)
- Credential-path protection (`~/.ssh`, `~/.aws`, `~/.gnupg`, `/etc/shadow`)
- Structured tool errors that prevent retry loops on fraud or compliance blocks

Out of scope:

- Securing the Claude API itself or the Anthropic platform
- Network or OS sandboxing beyond what Claude Code provides
- Authentication and secrets management for your own services (the examples
  read API keys from environment variables and stop there)

## Installation

Each example is self-contained inside its own directory and only writes
inside that directory. Nothing is installed system-wide unless you follow one
of the optional "make it global" steps, and each of those has a matching
uninstall step below.

### Get the code

```bash
git clone https://github.com/ruchirtewari/agent_security.git
cd agent_security
```

### Prerequisites

| Requirement | Install | Needed by |
|-------------|---------|-----------|
| Claude Code CLI | `npm install -g @anthropic-ai/claude-code` | all three examples |
| Python 3.9 or later | system package manager | `hooks-example`, `security-skill` |
| `mcp` package | `pip install -r hooks-example/requirements.txt` inside a venv | `hooks-example` only |

### Install hooks-example

```bash
cd hooks-example
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export REFUND_API_KEY="test-key-demo-123"   # any value works for the demo
```

The venv must live at `hooks-example/.venv` because `.mcp.json` starts the
server with `.venv/bin/python3`. The MCP server and both hooks are only
active when Claude Code is launched from inside `hooks-example/`. Before the
first run, Claude Code will ask you to approve the project MCP server; the
`settings.local.json` file in the directory pre-approves it.

### Install security-skill

The `/security` skill is discovered automatically when Claude Code starts in
`security-skill/`. No install step is needed for project-local use.

To make the skill available in every project:

```bash
mkdir -p ~/.claude/skills
cp -r security-skill/.claude/skills/security ~/.claude/skills/security
```

To activate the three hardening hooks in a project of your own, copy the
scripts and merge the hook config into that project's settings. Back up the
existing settings file first so the uninstall is a one-line restore:

```bash
cd /path/to/your-project
mkdir -p .claude/hooks
cp /path/to/agent_security/security-skill/.claude/hooks/{restrict-bash,sanitize-read,validate-output}.py .claude/hooks/
cp .claude/settings.json .claude/settings.json.bak 2>/dev/null || true
```

Then merge this into `.claude/settings.json`, keeping any keys already there:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "python3 .claude/hooks/restrict-bash.py" }] },
      { "matcher": "Read", "hooks": [{ "type": "command", "command": "python3 .claude/hooks/sanitize-read.py" }] }
    ],
    "PostToolUse": [
      { "matcher": "Bash|WebSearch|WebFetch", "hooks": [{ "type": "command", "command": "python3 .claude/hooks/validate-output.py" }] }
    ]
  },
  "permissions": {
    "deny": [
      "Bash(rm *)", "Bash(sudo *)", "Bash(curl * | *)", "Bash(wget * | *)",
      "Bash(chmod 777 *)", "Bash(dd *)", "Bash(mkfs*)", "Bash(git push --force *)"
    ]
  }
}
```

Verify a hook outside Claude Code before relying on it:

```bash
CLAUDE_TOOL_INPUT='{"command":"rm -rf /"}' python3 .claude/hooks/restrict-bash.py; echo "exit=$?"
# [security hook] BLOCKED: destructive rm -rf on root/home/glob
# exit=1
```

Start with the deny list and `restrict-bash.py` only, then add
`sanitize-read.py` once you have confirmed it does not block files you need.
A hook that blocks `Read` on a false positive can stall a session.

To schedule the nightly advisor, edit the `REPO` path at the top of
`nightly-suggestions.sh` and add one line to your crontab:

```bash
crontab -e
# 0 8 * * * /absolute/path/to/.claude/hooks/nightly-suggestions.sh
```

### Install command-example

The four commands are discovered automatically when Claude Code starts in
`command-example/`. To make any of them global:

```bash
mkdir -p ~/.claude/commands
cp command-example/.claude/commands/status.md ~/.claude/commands/
```

### Uninstall

Project-local installs are removed by deleting the directory. The global
steps are reversed as follows. Each command only touches files this README
told you to create.

| What you installed | How to remove it |
|--------------------|------------------|
| hooks-example venv | `rm -rf hooks-example/.venv` |
| hooks-example runtime output | `rm -f hooks-example/.claude/hooks/audit.log hooks-example/traces/*.jsonl` |
| `REFUND_API_KEY` in your shell | `unset REFUND_API_KEY` and remove the line from your shell profile if you added it |
| Global `/security` skill | `rm -rf ~/.claude/skills/security` |
| Hooks copied into your project | `rm .claude/hooks/{restrict-bash,sanitize-read,validate-output}.py` |
| Hook and deny config in your project | `mv .claude/settings.json.bak .claude/settings.json`, or delete the `hooks` and `permissions.deny` entries you added |
| Nightly advisor cron job | `crontab -e` and delete the `nightly-suggestions.sh` line; `rm .claude/nightly-report.md` |
| Global commands | `rm ~/.claude/commands/status.md` and any others you copied |
| Claude Code CLI | `npm uninstall -g @anthropic-ai/claude-code` |

Hooks and permission rules are read from `settings.json` at startup, so
restart Claude Code after removing them. Confirm with `/hooks` that the list
is empty.

## Tools

### 1. `hooks-example/` — MCP tool with Pre/PostToolUse hooks

A complete, runnable `process_refund` MCP tool wrapped in two hooks.

| File | Role |
|------|------|
| `mcp_tools/refund_server.py` | FastMCP server exposing `process_refund(customer_id, order_id, amount, reason)` |
| `.mcp.json` | Registers the server with Claude Code under the name `refund-tools` |
| `.claude/settings.json` | Wires both hooks to the matcher `mcp__refund-tools__process_refund` |
| `.claude/hooks/pre_process_refund.py` | **PreToolUse.** Blocks refunds over `$500` (exit 2), normalises IDs on the way through |
| `.claude/hooks/post_process_refund.py` | **PostToolUse.** Writes `audit.log`, enriches the result with `isRetryable`, `errorCategory`, `agentHint` |
| `run-refunds.sh` | End-to-end batch test: generates 8 cases, runs each through `claude -p`, scores the audit log and traces |
| `test-refunds.json`, `traces/TC-*.jsonl` | Generated test data and per-case stream-json traces |

The eight test cases cover success, boundary at `$499.99`, pre-hook block at
`$500.01` and `$1200`, negative and zero amounts, a simulated transient outage,
and a missing API key. See `hooks-example/README.md` for the full flow diagram,
exit-code table, and the list of anti-patterns the design avoids.

### 2. `security-skill/` — Security assessment skill plus hardening hooks

An interactive `/security` skill and three reusable hook scripts.

| File | Role |
|------|------|
| `.claude/skills/security/SKILL.md` | The `/security` skill. Asks 12 questions across three domains, scores gaps, then offers to implement fixes |
| `.claude/hooks/restrict-bash.py` | **PreToolUse on Bash.** Regex denylist: `rm -rf /`, `sudo rm`, `curl\|sh`, fork bombs, `dd` to raw disks, `mkfs`, force push to main, credential paths |
| `.claude/hooks/sanitize-read.py` | **PreToolUse on Read.** Scans the file for injection phrases ("ignore previous instructions", `<system>`, etc.) and blocks the read |
| `.claude/hooks/validate-output.py` | **PostToolUse on Bash / WebSearch / WebFetch.** Cannot block, so it prepends an explicit "treat as UNTRUSTED" warning when injection patterns appear |
| `.claude/hooks/nightly-suggestions.sh` | Cron-driven `claude -p` advisor that reports security gaps and uncommitted work |
| `Security.md` | Architecture overview of the control stack, permissions config, remaining gaps, and how to extend each layer |
| `security-skill.md` | Copy of `SKILL.md` kept at the top level for reading outside Claude Code |

The skill's three assessment domains:

- **Agentic orchestration.** Minimum footprint, output validation, injection defence, action gates.
- **Tool and MCP design.** Path privilege, input parameterisation, error strategy, single responsibility.
- **Claude Code config.** PreToolUse hooks, allow/deny lists, CI mode, `CLAUDE.md` security section.

After scoring, it can write the hooks and permission lists into
`.claude/settings.json`, append a security section to `CLAUDE.md`, and show
code patterns for each gap found.

### 3. `command-example/` — Custom slash commands

Three commands showing zero, one, and two-argument patterns and how a
directory becomes a namespace.

| Invocation | File | Arguments |
|------------|------|-----------|
| `/status` | `.claude/commands/status.md` | none |
| `/claudehelp <topic>` | `.claude/commands/claudehelp.md` | one |
| `/explain <concept>` | `.claude/commands/explain.md` | one |
| `/compare:files <a> <b>` | `.claude/commands/compare/files.md` | two |

Not security tooling in itself, but the same packaging mechanism is how you
would ship a `/security:audit` or `/deploy:check` command to a team. See
`command-example/README.md` for how `$ARGUMENTS` substitution works.

### Related files in the parent directory

Two files one level up are copies of material in `security-skill/`:

| Parent file | Relationship |
|-------------|--------------|
| `../Security.md` | Same content as `security-skill/Security.md` with a project-specific title |
| `../security-skill.md` | Identical to `security-skill/.claude/skills/security/SKILL.md` |

Treat the copies inside `security-skill/` as canonical.

## Usage

All three examples assume you have completed the matching step in
[Installation](#installation).

### hooks-example

Interactive:

```bash
cd hooks-example && source .venv/bin/activate
claude
# then inside Claude Code:
/hooks                                     # confirm both hooks are listed
Process a refund of $150 for customer CUST-456, order ORD-789. Reason: damaged.
Process a refund of $750 for customer CUST-123, order ORD-321.   # blocked
```

Batch test:

```bash
bash run-refunds.sh
```

The script prints a per-case PASS/FAIL table and leaves traces in `traces/`
and the audit trail in `.claude/hooks/audit.log`.

### security-skill

```bash
cd security-skill
claude
/security            # full assessment, then offers fixes
/security --fix      # skip questions, go straight to implementation
```

Once the hooks are wired into a project, any blocked command shows up in the
Claude Code session as a tool error prefixed with `[security hook] BLOCKED`.
Run the nightly advisor by hand with
`bash .claude/hooks/nightly-suggestions.sh`.

### command-example

```bash
cd command-example
claude
/status
/claudehelp hooks
/compare:files README.md ../hooks-example/README.md
```

## Extending

- **New dangerous command.** Append a `(regex, reason)` tuple to `DENYLIST` in `restrict-bash.py`.
- **New injection phrase.** Add the regex to `INJECTION_PATTERNS` in both `sanitize-read.py` and `validate-output.py`.
- **New guarded MCP tool.** Follow the six-step recipe under "Adapting to a new tool" in `hooks-example/README.md`. The matcher format is `mcp__<server>__<tool>`.
- **Fewer permission prompts.** Run `/fewer-permission-prompts` to generate an allowlist from your transcripts. Hooks and deny lists keep enforcing even under `--dangerously-skip-permissions`.
