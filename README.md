# circus

A personal engineering supervisor. Open Claude in this directory and talk to
the **handler**, who dispatches **legmen** (coders), **watchers** (reviewers),
and **ferrets** (researchers) into your registered repos to do work on your
behalf.

See [`CLAUDE.md`](./CLAUDE.md) for the handler's full playbook — the rules,
vocabulary, repo taxonomy, mission lifecycle, and PR review loop.

## Status

Early. Scaffolding and a working end-to-end mission flow exist; everything
beyond is in the *Planned* section at the bottom of `CLAUDE.md`.

## Quickstart (for the user)

1. Open Claude in `~/code/circus/`. The handler's playbook loads automatically.
2. Talk to the handler in plain English. Examples:
   - *"send a legman to circus-testbed to fix the bug in `reverse` when input is empty"*
   - *"what's pending?"*
   - *"the watcher on mission 20260517-1430-bug-fix came back with notes — send them to the legman"*

You never need to call the CLI directly; the handler invokes `bin/` scripts on
your behalf.

## Layout

```
bin/         # scripts the handler calls via Bash
hooks/       # Stop hook + settings template that get copied into worker worktrees
meta/        # hierarchical knowledge files (contexts, subjects)
CLAUDE.md    # handler playbook (auto-loaded by Claude in this dir)
repos.yml    # catalog of registered repos
~/.circus/   # state directory (missions, inbox) — outside the repo
```

## Dependencies

- `tmux` (orchestration)
- `gh` (GitHub CLI, authenticated)
- `claude` (Claude Code CLI)
- `jq` and `yq` (state file manipulation)
- macOS Terminal.app (for optional auto-attached windows)
