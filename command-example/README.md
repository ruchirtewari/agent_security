# Custom Command Examples

Three examples showing zero, one, and two-argument custom commands.

## Directory layout

```
command-example/
└── .claude/
    └── commands/
        ├── status.md          →  /status          (zero args)
        ├── claudehelp.md      →  /claudehelp       (one arg)
        └── compare/
            └── files.md       →  /compare:files    (two args)
```

To use these commands, open Claude Code from the `command-example/` directory:

```bash
cd command-example
claude
```

---

## The three commands

### `/status` — zero arguments

```
/status
```

Runs `git status`, `git log`, and `git stash list` then prints a structured
project health snapshot. No input needed.

---

### `/claudehelp <topic>` — one argument

```
/claudehelp hooks
/claudehelp plan-mode
/claudehelp              ← no arg: lists available topics
```

`$ARGUMENTS` in the command file is replaced with whatever you type after
`/claudehelp`. If nothing is typed, `$ARGUMENTS` is an empty string and the
command falls back to showing a topic list.

Available topics: `hooks`, `commands`, `mcp`, `permissions`, `memory`,
`sessions`, `tools`, `settings`, `plan-mode`, `non-interactive`

---

### `/compare:files <file-a> <file-b>` — two arguments

```
/compare:files src/old.py src/new.py
/compare:files README.md docs/README.md
```

Both paths are passed together as `$ARGUMENTS`. The command itself
instructs Claude to split on the first space to get file A and file B.

---

## `/command` vs `/command:subcommand`

The colon separates a **namespace** from a **subcommand**. It maps directly
to the directory structure of `.claude/commands/`:

| Invocation | File path |
|---|---|
| `/status` | `.claude/commands/status.md` |
| `/claudehelp` | `.claude/commands/claudehelp.md` |
| `/compare:files` | `.claude/commands/compare/files.md` |

`compare/` is a directory, not a file. Any `.md` file inside it becomes a
subcommand under the `/compare:` namespace:

```
.claude/commands/compare/files.md    →  /compare:files
.claude/commands/compare/dirs.md     →  /compare:dirs
.claude/commands/compare/branches.md →  /compare:branches
```

**Why use namespaces?**

Group related commands so they are discoverable together. Typing `/compare`
and hitting Tab shows all subcommands. Common patterns:

```
/db:migrate   /db:seed    /db:reset
/test:unit    /test:e2e   /test:coverage
/deploy:stg   /deploy:prd
```

Top-level commands (no colon) are one-off utilities. Namespaced commands
(with colon) are families of related operations.

---

## How `$ARGUMENTS` works

`$ARGUMENTS` is a literal string substitution — everything the user types
after the command name is dropped in verbatim:

```
/claudehelp hooks         →  $ARGUMENTS = "hooks"
/compare:files a.py b.py  →  $ARGUMENTS = "a.py b.py"
/status                   →  $ARGUMENTS = ""
```

There are no `$1` / `$2` positional variables. For multi-argument commands,
write instructions in the markdown telling Claude how to parse `$ARGUMENTS`
(e.g. "split on the first space").

---

## Where to place commands

| Location | Scope |
|---|---|
| `~/.claude/commands/` | Available in every project (user-level) |
| `.claude/commands/` | Available only in this project |

Project commands take precedence over user commands if names collide.
