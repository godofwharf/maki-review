# maki-review

A [maki](https://github.com/tontinton/maki) plugin that adds a `/review` command:
a TUI for reviewing maki's changes, leaving inline comments on diff lines,
and having maki agents work through them.

> This is a fork of, and heavily inspired by,
> [Asaf51/maki-review](https://github.com/Asaf51/maki-review). The TUI, diff
> rendering and overall workflow come from that project; this fork adds
> persistent, multi-agent review state on top.

## Features

- **Files**: changed files vs `HEAD` (staged, unstaged, untracked) as a collapsible tree
- **Commits**: recent commits; drill into a commit's files
- **Comments**: review comments with status (open, in progress, resolved, stale, won't fix)
- **Diff pane**: syntax-highlighted diff, unified or side-by-side, hunks or whole file;
  comment a line (`c`), select a range first (`v`), delete (`d`)
- **Persistent reviews**: comments are stored in SQLite outside the repo, scoped by
  repo + worktree + branch, and survive restarts
- **Agent tools**: `review_*` tools let agents list, claim, resolve and add comments,
  safely under concurrent agents
- **Review picker** (`R`): browse reviews across branches and worktrees
- **Submit**: `s` sends open comments to a new maki session that works through them
  with the review tools

## Keys

| Key | Action |
| --- | --- |
| `Tab` | cycle left panels (in the diff: next change or comment) |
| `Enter` / `l` | open dir / focus diff / open commit |
| `h` / `Esc` | collapse / back |
| `c` | comment on the current diff line |
| `v` | start range selection |
| `t` / `f` | toggle side-by-side / whole file |
| `n` / `p` | next / previous file |
| `d` | delete your own open comment |
| `x` / `o` / `w` | resolve / reopen / won't fix (Comments pane) |
| `e` | edit your own comment (Comments pane) |
| `h` | hide / show closed comments (Comments pane) |
| `R` | review picker |
| `s` | send open comments to maki |
| `r` | refresh |
| `?` | help |
| `q` | quit |

## Agent tools

| Tool | Purpose |
| --- | --- |
| `review_list_comments` | list comments (default: open + in progress) |
| `review_get_comment` | full body, snippet, resolution and history |
| `review_claim_comment` / `review_release_comment` | take / give back a comment (claims expire after 30 min) |
| `review_resolve_comment` | resolve with a note and optional commit sha |
| `review_mark_stale` / `review_reopen_comment` | mark stale / reopen |
| `review_add_comment` | add a comment on lines of a file |

The tools always act on the repo, worktree and branch of the session's working directory.

## Storage

Reviews live in `~/.local/state/maki/review/review.db` (maki's state dir when the
plugin has `fs_read`), accessed via `/usr/bin/sqlite3`. Each operation is a single
transaction with a busy timeout; mutations use optimistic version checks and every
status change is recorded as an event.

## Install

As a package, in `~/.config/maki/init.lua`:

```lua
maki.pack.add({ "https://github.com/godofwharf/maki-review" })
```

Or copy `lua/*.lua` into `~/.config/maki/lua/` and add `require("review")` and
`require("review_tools")` to your `init.lua`. The plugin needs the `run` permission
and `sqlite3` on the system.
