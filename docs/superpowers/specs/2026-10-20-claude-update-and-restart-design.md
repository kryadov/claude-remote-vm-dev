# Updating Claude Code under long-running sessions

Design document. Extends `2026-08-15-remote-claude-code-vm-design.md`; read
that first — this document only describes what changes.

## 1. Problem

Sessions on the VM live for days. Claude Code ships several releases a week.
Nothing on the VM ever moves a running session to a newer release:

- `bootstrap.sh` installs Claude with `sudo npm install -g`, so the CLI's own
  auto-updater (and `claude update`) cannot write the global prefix without
  root. `"autoUpdatesChannel": "latest"` in the default settings is inert.
- Even after a manual `sudo npm install -g`, a running process keeps executing
  the old binary (Linux keeps the unlinked inode alive). The new release only
  takes effect when the process is restarted.
- Restarting by hand means: attach, find a quiet moment, exit, retype
  `claude --dangerously-skip-permissions --continue`, and hope `--continue`
  picks the right conversation.

## 2. Goals and non-goals

**Goals**

- One command — and one key in `rd-tui` — that restarts a session's Claude on
  the installed release and resumes the *same* conversation.
- A separate, idempotent command that installs the latest release, so ten
  sessions do not mean ten npm runs.
- Never kill a turn in progress unless explicitly forced.
- Show which sessions run an older release than the installed one, so the user
  can see *when* a restart is due.
- Keep the user's `~/.claude/settings.json` untouched.

**Non-goals**

- Automatic restarts (a nightly timer restarting idle, outdated sessions is a
  natural follow-up built on the same commands, but not part of this change).
- Preserving background processes Claude started in the pane — they die with
  it. Docker containers survive, as they do across `rd-stop`.

## 3. Approved decisions

| Question | Decision |
| --- | --- |
| Update and restart in one step? | No: `rd-update` (per VM) and `rd-restart` (per session); `rd-restart --update` chains them. |
| How is the conversation remembered? | A `SessionStart` hook writes the session id to the tmux user option `@rd_claude_session`; restart uses `--resume <id>`, falling back to `--continue` for sessions that predate the hooks. |
| How are hooks installed? | Through `claude --settings <file>` on the command line, from a file rd owns — not by merging into `~/.claude/settings.json`. |
| When is a restart safe? | Hooks track `@rd_claude_state` (`idle` / `busy` / `exited`); `rd-restart` refuses anything but `idle`/`exited` without `--force`. |
| How is Claude stopped? | `tmux respawn-pane -k` on the pane Claude runs in, then the launcher is typed into the fresh login shell — the same path `rd-start` takes. |

## 4. Components

### 4.1 `rd-claude` — the one launcher

Every rd session now starts Claude through `bin/rd-claude`, which `rd-start`
and `rd-restart` type into the pane with `send-keys`. It:

1. writes `~/.config/rd/claude-settings.json` (atomically, every launch, so a
   repo update refreshes the hooks) containing only the `hooks` block below;
2. when running inside tmux, records `@rd_claude_version` (the first word of
   `claude --version`) and `@rd_claude_pane` (`$TMUX_PANE`) on the session;
3. `exec claude --dangerously-skip-permissions --settings <file> "$@"`.

Because the hooks arrive only through `--settings`, a Claude the user starts by
hand in another window of the same tmux session has no hooks and cannot
overwrite the session's recorded id or state. Running `rd-claude --continue`
by hand after exiting Claude restores the managed behaviour.

`--settings` adds to the user's settings rather than replacing them; hook
arrays from both sources run.

### 4.2 `rd-claude-hook <event>`

Called by the hooks with the hook JSON on stdin. It prints nothing (stdout of
`SessionStart` and `UserPromptSubmit` hooks is injected into Claude's
context) and always exits 0 — a broken hook must never block Claude.

| Hook | Event arg | Effect |
| --- | --- | --- |
| `SessionStart` | `session-start` | `@rd_claude_session=<session_id>`, state `idle` |
| `UserPromptSubmit` | `prompt` | state `busy` |
| `Stop` | `stop` | state `idle` |
| `SessionEnd` | `session-end` | state `exited` |

Each state write also stores `@rd_claude_state_at` (epoch). The session id is
parsed with a bash regex (no `jq` dependency) and accepted only if it matches
`^[A-Za-z0-9-]+$`, because `rd-restart` later types it into a shell. Outside
tmux (`$TMUX_PANE` unset) the hook does nothing. `SessionStart` also fires
after `/clear` and `/resume`, so the recorded id follows the conversation the
user is actually in.

Known gap: an interrupted turn (Esc) fires no `Stop`, so the state stays
`busy` until the next prompt completes. `rd-restart` reports how long the
state has been `busy` so the user can judge whether `--force` is safe.

### 4.3 `rd-restart <project> [--session <name>] [--force] [--update]`

1. Resolves and verifies the tmux session exactly like `rd-stop` (metadata
   collision checks); a stopped session is an error — use `rd-start`.
2. With `--update`, runs `rd-update` first and aborts if it fails.
3. Reads `@rd_claude_state`. `idle` or `exited` proceed. Anything else —
   `busy`, or empty for a session started before this change — exits **3**
   with an explanation, unless `--force`. Exit 3 lets `rd-tui` offer the
   forced restart.
4. Picks the resume argument: `--resume <id>` if the id is recorded and its
   transcript `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/<id>.jsonl` exists;
   `--continue` if no id is recorded (legacy session); no argument, with a
   warning, if the id is recorded but its transcript is gone.
5. `tmux respawn-pane -k -c <worktree>` on `@rd_claude_pane` (falling back to
   the session's current pane), clears the recorded state, then
   `send-keys` the `rd-claude` command.

The pane id survives `respawn-pane`, and so does the session environment, so a
`RD_PROVIDER` injected by `rd-start --provider` reaches the new login shell:
the session's provider is unchanged, consistent with "a session's provider is
fixed when its pane starts".

### 4.4 `rd-update [<version>]`

1. Reads the installed version (`claude --version`).
2. Finds the target: the argument, or `npm view @anthropic-ai/claude-code
   version`.
3. If equal, prints "already on <v>" and exits 0 — safe to call repeatedly.
4. Installs: `sudo npm install -g @anthropic-ai/claude-code@<v>` when Claude
   is an npm global package (`npm ls -g @anthropic-ai/claude-code`), otherwise
   `claude update` (native installer, user-writable).
5. Verifies `claude --version` runs and reports the target. If not — the
   per-platform native package has lagged before (see AGENTS.md) — it
   reinstalls the previous version and exits 1, naming
   `npm view @anthropic-ai/claude-code-linux-x64 versions`.

No session is touched; running processes keep their binary.

### 4.5 `rd-list` and `rd-tui`

`rd-list --porcelain` appends three columns (older readers stop earlier and
keep working):

| # | Column | Values |
| --- | --- | --- |
| 8 | activity | `idle`, `busy`, `exited`, empty (unknown) |
| 9 | claude | version the session started with, empty if unknown |
| 10 | update | `outdated` if 9 differs from the installed version |

The human table gains `ACTIVITY` and `CLAUDE` columns; an outdated version is
marked with `*` and explained under the table.

`rd-tui` shows the same two columns and adds:

- `u` — restart the selected running session on the latest release
  (`rd-restart --update`); on exit 3 it asks whether to force.

All rules stay in `rd-restart` / `rd-update`; the TUI only renders and asks.

## 5. Error handling

| Situation | Behaviour |
| --- | --- |
| Session busy / state unknown | `rd-restart` exit 3, message with state age and `--force` hint |
| Session not running | exit 1, "start it with rd-start" |
| npm has no newer release | `rd-update` exits 0, nothing installed |
| New release lacks its native binary | `rd-update` rolls back, exits 1 |
| Recorded transcript missing | restart without resume, warning printed |
| Hook fails for any reason | silent, exit 0; worst case the state is stale |

## 6. Testing

- `tests/test-rd-restart.sh` (stubbed `tmux`, `claude`, `npm`, `sudo`):
  hook parsing and state transitions, id validation, the busy/unknown refusal
  and exit code, `--force`, resume-argument selection, `respawn-pane` target,
  `rd-update` no-op / install / rollback paths, and the `rd-list` columns.
- `tests/test-rd-tui.sh`: the `u` key, including the force prompt.
- `tests/smoke/smoke-provider.sh`: after `respawn-pane`, a `--provider`
  session still sees its provider (the mechanism the stub cannot prove).
- The tmux stub's `list-sessions` now renders any `#{…}` format field instead
  of a fixed set of layouts.

## 7. Files touched

`bin/rd-claude`, `bin/rd-claude-hook`, `bin/rd-restart`, `bin/rd-update`
(new); `bin/rd-start`, `bin/rd-list`, `bin/rd-tui`, `tests/stubs/tmux`,
`tests/test-rd-tui.sh`, `tests/smoke/smoke-provider.sh`, `bootstrap.sh`
(next-steps text), `README.md`, `AGENTS.md`.

## 8. Compatibility

- Sessions started before this change have no hooks: they show empty
  activity/version, and `rd-restart` needs `--force` once; it then resumes with
  `--continue` and the restarted Claude has hooks from then on.
- VMs that are not re-bootstrapped pick the new helpers up with the usual
  `install -m 0755 bin/rd-* ~/.local/bin/` (or re-running `bootstrap.sh`).
