# AGENTS.md

Guidance for AI agents and contributors working in this repository.

## What this repo is

**claude-remote-dev**: tooling to run Claude Code sessions on a server-side VM
inside the org perimeter, so sessions keep running while the laptop is off and
you reconnect to review, answer questions, and manage them. Models are reached
through **one of three providers** — GCP Vertex AI (user ADC, no
service-account keys), Amazon Bedrock, or the direct Anthropic API — chosen per
VM in `rd.env` and overridable per session with `rd-start --provider`.

The full rationale and decisions live in
`docs/superpowers/specs/2026-08-15-remote-claude-code-vm-design.md`, extended by
`docs/superpowers/specs/2026-08-15-github-and-multi-provider-design.md` (GitHub
alongside GitLab, Bedrock/Anthropic alongside Vertex). Read them before changing
the architecture.

## Architecture in one paragraph

**Variant A**: Claude Code runs *natively* on the VM (not in a container), so it
can drive `docker compose` directly; the **VM is the isolation boundary** and is
treated as disposable. **tmux** hosts one session per `<project>/<session>`;
named sessions use isolated Git worktrees under
`~/worktrees/<project>/<session>` and branches named `feature/<session>` or
`bugfix/<session>`. A **systemd user service + `loginctl enable-linger`** keeps
the tmux server alive across disconnects and reboots. **VS Code Remote-SSH** is
the client for diffs/editing; a project-scoped automatic task can run
`rd-attach-here` when a worktree is opened. Autonomy is achieved with
`claude --dangerously-skip-permissions`.

Provisioning is two commands: `bootstrap-remote.sh` from the laptop (clones the
repo onto the VM with a throwaway `GIT_CLONE_TOKEN`, copies `rd.env`, runs
`bootstrap.sh` there), then `rd-auth` on the VM for the one-time logins.

The **laptop side is cross-platform**: every helper exists as `*.sh` plus a
PowerShell/cmd twin (`connect.ps1`/`.bat`, `sessions.ps1`/`.bat`). Change them
together — the flags mirror each other (`--tui` ↔ `-Tui`, `--session` ↔
`-Session`). Only `bootstrap-remote.sh` and `sync-memory.sh` are Bash-only (run
from Git Bash on Windows).

## Integrations available on the VM

- **GitLab** via `glab` (installed by bootstrap from the latest `linux_amd64.deb`
  on the GitLab releases API — there is no signed apt repo for it) and **GitHub**
  via `gh` (installed from GitHub's signed apt repo): create MRs/PRs, watch
  pipelines and checks. Neither is wrapped — both read the repository's own
  `origin`, so the forge is resolved per checkout.
- **Git credential helpers are host-scoped**, never global
  (`credential.https://<host>.helper`). A global `glab` helper answers for
  GitHub hosts too and breaks every GitHub push; `rd-auth` migrates a legacy
  global one automatically.
- **Model providers** live one-per-file in `~/.config/rd/providers/<name>.env`
  (mode 0600), with the VM default in `~/.config/rd/provider`. `~/.profile`
  sources exactly one of them — tmux panes are login shells, which is what makes
  this work. `rd-start --provider` overrides it by passing **only the provider
  name** through `tmux new-session -e RD_PROVIDER=…`.
- **`rd-auth` is the single authorization entrypoint** on the VM: the model
  provider (Vertex ADC / `aws sso login` / `claude setup-token`), the forge
  login (`glab auth login` or `gh auth login` + `gh auth setup-git`), the
  host-scoped credential helper, and `git user.name/user.email` (read from
  `rd.env`; it exits if they are unset, so VM commits are never attributed to
  `<user>@<hostname>`). Add new logins there, not to `bootstrap.sh` — bootstrap
  must stay non-interactive.
- **Jira/Confluence** via the official **`atlassian` plugin** (bootstrap installs
  it from the `anthropics/claude-plugins-official` marketplace). It exposes an
  HTTP MCP at `mcp.atlassian.com` with OAuth; skills call
  `mcp__plugin_atlassian_atlassian__*` tools. Install the *plugin* (not a bare
  `claude mcp add`) so those tool names resolve.
- The repo itself is delivered to the VM by **`git clone`**, not file copy.

## Layout

```
bootstrap.sh                 # idempotent VM installer (run ON the VM)
bootstrap-remote.sh          # laptop-side: clone repo onto the VM, copy rd.env, run bootstrap
connect.sh / .ps1 / .bat     # laptop-side SSH helper (reads rd.env); --tui / start+attach
sessions.sh / .ps1 / .bat    # laptop-side: list VM sessions without attaching
sync-memory.sh               # laptop-side: push/pull ~/.claude/projects/<path>/memory
rd.env.example               # config template -> copy to rd.env (gitignored)
bin/rd-*                     # tmux session helpers, installed to ~/.local/bin
bin/rd-auth                  # one-command VM authorization (provider + forge + git author)
bin/rd-tui                   # interactive picker; shells out to the other rd-*
bin/rd-vscode-init           # writes a project-scoped automatic attach task
bin/rd-attach-here           # attaches the session owning the opened worktree
tmux.conf                    # installed to ~/.tmux.conf (mouse scrolling) if absent
tests/lib.sh, tests/stubs/   # shared test helpers and the tmux/ssh stubs
tests/smoke/                 # real-tmux and real-bootstrap smoke runs (no stubs)
systemd/tmux-claude.service  # persistent tmux user service
hardening/                   # sshd drop-in, unattended-upgrades, egress allowlist
docs/superpowers/specs/      # design documents
docs/superpowers/plans/      # implementation plans
```

Provider config written by `bootstrap.sh` (on the VM, not tracked):

```
~/.config/rd/provider              # default provider name for new sessions
~/.config/rd/providers/<name>.env  # 0600, sourced by ~/.profile for that provider
```

## Conventions

- **Everything must stay anonymized.** No real hostnames, IPs, project ids,
  emails, or key names in tracked files. Environment-specific values belong in
  `rd.env` (gitignored) and are referenced via the placeholders documented in
  the design doc (`<VM_IP>`, `<GCP_PROJECT_ID>`, etc.).
- **Shell scripts:** `bash`, start with `set -euo pipefail`. Keep them
  **idempotent** — `bootstrap.sh` is expected to be re-run safely. Guard
  file edits with markers (see the `>>> remote-dev vertex >>>` block).
- **Session identity:** preserve `claude-<project>` for `default`; named tmux
  sessions use `claude-<project>--<session>`. Store project, session, and
  worktree as tmux user options instead of parsing the tmux name. Before any
  attach/stop/reuse, verify metadata so a legacy default name containing `--`
  cannot be mistaken for a named session.
- **Worktree safety:** `rd-stop` only stops tmux. Cleanup belongs in
  `rd-remove`, which rejects active sessions and dirty worktrees and never
  forces branch deletion.
- **`rd-tui` owns no logic.** It renders and shells out to `rd-start` /
  `rd-attach` / `rd-stop` / `rd-remove`, and enumerates through
  `rd-list --porcelain --all` (the one place that knows a stopped session is a
  `~/worktrees/<project>/<session>` directory with no tmux session). Keep new
  rules in the command that owns them so the CLI and the TUI cannot diverge.
- **No secrets in git.** `rd.env`, `*.pem`, `*.key` are gitignored; keep it that
  way. Never echo tokens or credentials into tracked files.
- **Provider secrets stay in files, not in arguments.** Credentials belong in
  `~/.config/rd/providers/*.env` at mode 0600. Only `RD_PROVIDER` may cross the
  tmux boundary — putting a key on a `tmux new-session -e` command line would
  expose it in `ps` output and in the session environment.
- **A session's provider is fixed when its pane starts.** `rd-start` rejects a
  `--provider` that disagrees with a running session rather than pretending to
  switch it. On a VM with no provider config at all (provisioned before this
  existed), `rd-start` falls back to whatever `~/.profile` already exports
  instead of refusing to start.
- **Prefer signed apt repos over piped installers** (`curl | sudo sh`), matching
  the org's security posture — see how `gcloud` is installed in `bootstrap.sh`.
  When a tool ships no signed repo (`glab`), fetch a versioned release artifact
  and `dpkg -i` it; warn and continue rather than failing the whole bootstrap.
- **Docs are part of the change.** `README.md` is the user-facing runbook and its
  Layout block must match this file's; the design doc under
  `docs/superpowers/specs/` is the rationale. A new flag or helper that appears
  in none of them is not finished.

## Build & test

There is no compiler; validation is static + a live smoke test on a VM.

- Syntax-check scripts: `bash -n bootstrap.sh bootstrap-remote.sh connect.sh
  sessions.sh sync-memory.sh bin/rd-*`.
- Lint (if available): `shellcheck -S warning bootstrap.sh bootstrap-remote.sh
  connect.sh sessions.sh sync-memory.sh bin/rd-*`.
- Session tests: `bash tests/test-rd-sessions.sh`.
- TUI tests: `bash tests/test-rd-tui.sh` (drives `rd-tui` by piping keystrokes;
  `\033[B` is arrow-down, an empty line is enter).
- Auth tests: `bash tests/test-rd-auth.sh` (stubs `gcloud`/`glab`/`gh`/`aws`/
  `claude`/`git`) — covers every provider and forge path.
- Provider tests: `bash tests/test-rd-provider.sh` (`rd-start --provider`
  resolution, the tmux `-e` injection, and the `rd-list` provider column).
- PowerShell helper test: `powershell -NoProfile -ExecutionPolicy Bypass -File
  tests/test-connect.ps1`.
- Tests stub the outside world (`tests/stubs/tmux`, `tests/stubs/ssh`) and run
  against a temp `HOME`; they must never touch a real VM or the user's tmux.
- Provider smoke (real tmux, real login shell, real worktree — proves the
  `~/.profile` + `tmux -e RD_PROVIDER` mechanism the stubs cannot):
  `bash tests/smoke/smoke-provider.sh .`
- `bootstrap.sh` smoke, in a throwaway container only:
  `docker run --rm -v "$(pwd)":/src -w /work ubuntu:24.04 bash -c 'cp -r /src/. /work/ && bash /work/tests/smoke/smoke-bootstrap.sh'`
  It checks the installs, provider files, the `~/.profile` migration and
  idempotency. `loginctl`/`systemctl --user` cannot work in a container and end
  the run at that section — expected, not a failure.
- **Smoke test** (the real gate) — on a throwaway VM: run `bootstrap-remote.sh`,
  verify `node`/`claude`/`gcloud`/`glab`/`docker` versions, run `rd-auth`, start
  two named sessions in one project, verify their isolated worktrees and VS Code
  automatic attach, then disconnect and confirm the session survives. After a
  reboot expect the tmux *server* back automatically (linger) but the sessions
  gone — restart them with `rd-start`; the worktrees and branches persist.
  Full steps are in the design doc's §8.

## Things that go wrong

- **`gh` assumes one checkout per repository, and this repo is built on
  worktrees.** `gh pr close <n> --delete-branch` tries to switch the local
  checkout to the base branch first, which fails when another worktree holds it:
  `fatal: 'master' is already used by worktree at ~/projects/<project>`. The PR
  still closes, but the branch survives on the remote. Delete it explicitly —
  `git push origin --delete <branch>` — then clean up locally with `rd-remove`.
  Expect the same class of failure from any `gh` subcommand that checks out a
  branch (`gh pr checkout`, `gh pr merge --delete-branch`).
- **`rd-remove --delete-branch` refuses unmerged branches, by design.** It uses
  `git branch -d`, so after a *closed* (not merged) PR the branch stays and git
  prints its own "not fully merged" error next to rd-remove's "branch preserved"
  line. That pair reads like a contradiction but is correct; force it yourself
  with `git branch -D` if you really mean it.
- `systemctl --user` needs a running user manager; `bootstrap.sh` calls
  `loginctl enable-linger` first so the service persists without a login. If the
  service fails to start, re-login and re-run the enable step.
- The `docker` group grant only takes effect after re-login (`newgrp docker` or
  a fresh SSH session).
- The egress allowlist (`hardening/egress-allowlist.nft`) is **deferred and
  approximate** — nftables matches IPs, not domains. Test it interactively
  before persisting to `/etc/nftables.conf`, or it can cut off Vertex/apt.
- ADC login on a headless VM must use `--no-launch-browser` (URL/device flow).
- **`claude` installs but every call fails** ("native binary not installed").
  The binary ships as an optional per-platform npm package, and those sometimes
  lag the main package — `@anthropic-ai/claude-code@2.1.237` shipped while
  `…-linux-x64@2.1.237` was unpublished, so npm "succeeded" with a stub.
  `bootstrap.sh` now checks `claude --version` and warns. Fix by pinning the
  last release that has a platform package:
  `npm view @anthropic-ai/claude-code-linux-x64 versions`, then
  `sudo npm install -g @anthropic-ai/claude-code@<version>`.
- **Bridging a VM over Wi-Fi destroys throughput** (802.11 forbids a station
  sending foreign MAC addresses; the hypervisor fakes it). Symptom: normal
  latency and zero packet loss, but ~10 KB/s to the internet while the LAN runs
  at full speed. Use NAT with a forwarded SSH port instead — that alone took a
  test VM from 8.8 KB/s to 9.1 MB/s.

## Merging MRs and PRs (both forges lie)

Neither CLI's merge is one-shot — confirm the real state before moving on.

**GitLab.** `glab mr merge <iid> --squash` prints "✓ Merged!" but that may only
set `merge_when_pipeline_succeeds`; the MR can stay open on unresolved
discussions. Confirm with `glab api projects/:id/merge_requests/<iid>`
(`state: merged`) and `git ls-remote origin refs/heads/main`, then
`git pull --ff-only`.

**GitHub.** `gh pr merge <n> --squash` queues the merge instead of merging when
required checks are still pending, and branch protection can reject a merge the
CLI reported as submitted. Confirm with
`gh pr view <n> --json state,mergedAt` (`"state": "MERGED"`), then
`git pull --ff-only`.
