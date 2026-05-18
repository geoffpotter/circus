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

1. Run `bin/handler.sh`. That opens Claude inside a tmux session named
   `handler`, with `~/code/circus/` as the cwd. The playbook (`CLAUDE.md`)
   auto-loads.
2. Register your first repo: `bin/add-repo.sh <github-url>` (or tell the
   handler to do it).
3. Talk to the handler in plain English. Examples:
   - *"send a legman to circus-testbed to fix the bug in `reverse` when input is empty"*
   - *"what's pending?"*
   - *"the watcher on mission ... came back with changes — respawn the legman"*

You never need to call the CLI directly; the handler invokes `bin/` scripts on
your behalf.

## Layout

Everything (including registered repos and their wikis) lives under
`~/code/circus/` so a single `grep -r` finds it all. Repo clones,
worktrees, missions, and wikis are gitignored — the tracked tree only
holds the tooling.

```
bin/                 scripts the handler calls via Bash
hooks/               Stop hook for workers
meta/                hierarchical knowledge files (contexts, subjects)
CLAUDE.md            handler playbook (auto-loaded by Claude in this dir)
repos.yml            catalog of registered repos

repos/<name>/        cloned working checkout of each registered repo
worktrees/<id>/      per-mission branch checkouts
wikis/<name>/        cloned <repo>.wiki.git
wiki/                circus's own wiki
missions/<id>/       brief, status, transcript, review for each mission
missions/done/<id>/  archive after close-mission.sh
inbox.json           snapshot of active missions
inbox.jsonl          append-only log of worker pings (no tmux interrupts)
```

## Dependencies

- `tmux` (orchestration)
- `gh` (GitHub CLI, authenticated)
- `claude` (Claude Code CLI)
- `jq` and `yq` (state file manipulation)
- macOS Terminal.app (for optional auto-attached windows)
