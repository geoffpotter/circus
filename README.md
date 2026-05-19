# circus

A personal engineering supervisor. Open Claude in this directory and talk to
the **handler**, who dispatches **legmen** (coders), **watchers** (reviewers),
and **ferrets** (researchers) into your registered repos to do work on your
behalf.

Workers run as Claude Code background sessions (`claude --bg`) so the
Claude Code supervisor owns process lifecycle; circus owns multi-repo
dispatch, mission state, GitHub-native workflow (issue mirroring, PR
review loop, contributor push patterns), and the unified
`~/code/circus/` filesystem layout.

See [`CLAUDE.md`](./CLAUDE.md) for the handler's full playbook.

## Status

Early but working end-to-end on owned repos with `issues_mode: mirror`.
Contributor flow is wired but not yet exercised. See *Planned* at the
bottom of `CLAUDE.md`.

## Quickstart

1. **Symlink agent definitions** so workers find them anywhere:

       ln -sfn ~/code/circus/agents ~/.claude/agents/circus

2. **Open Claude** in this directory:

       cd ~/code/circus && claude

   The handler playbook (`CLAUDE.md`) auto-loads. Or hit `←` from inside
   `claude agents` to land here.

3. **Register your first repo:** `bin/add-repo.sh <github-url>` (or just
   tell the handler to do it).

4. **Dispatch in plain English:**
   - *"send a legman to circus-testbed to fix the bug in `reverse` when input is empty"*
   - *"what's pending?"*
   - *"the watcher on mission ... came back with changes — respawn the legman"*

The handler invokes `bin/` scripts and uses Claude Code's native
`claude --bg / agents / attach / logs / stop / rm` for worker lifecycle.

## Layout

Everything (including registered repos and their wikis) lives under
`~/code/circus/` so a single `grep -r` finds it all. Repo clones,
worktrees, missions, and wikis are gitignored — the tracked tree only
holds the tooling.

```
bin/                 scripts the handler calls via Bash
agents/              legman.md / watcher.md / ferret.md role definitions
meta/                hierarchical knowledge files (contexts, subjects)
CLAUDE.md            handler playbook (auto-loaded by Claude in this dir)
repos.yml            catalog of registered repos

repos/<name>/        cloned working checkout of each registered repo
worktrees/<id>/      per-mission branch checkouts
wikis/<name>/        cloned <repo>.wiki.git
wiki/                circus's own wiki
missions/<id>/       brief, status, review for each mission
missions/done/<id>/  archive after close-mission.sh
inbox.json           snapshot of active missions
inbox.jsonl          append-only log of state transitions (no tmux interrupts)
```

## Dependencies

- `claude` ≥ 2.1.144 (Claude Code CLI; needs `claude --bg` and `claude agents`)
- `gh` (GitHub CLI, authenticated)
- `jq` and `yq` (state file manipulation)
- macOS for `osascript`-based notifications (optional; falls back silently)
