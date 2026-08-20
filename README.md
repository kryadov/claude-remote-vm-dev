# claude-remote-dev

Run **Claude Code sessions server-side** on a VM inside the org perimeter, so
they keep working while your laptop is off. Reconnect from the laptop to review
changed files, answer questions, finish or start sessions.

Claude models are reached through one of three providers — **GCP Vertex AI**,
**Amazon Bedrock**, or the **direct Anthropic API** — chosen per VM and
overridable per session. Repositories can live on **GitLab or GitHub**
(github.com and GitHub Enterprise Server alike).

See the full design in
[`docs/superpowers/specs/2026-08-15-remote-claude-code-vm-design.md`](docs/superpowers/specs/2026-08-15-remote-claude-code-vm-design.md),
and the multi-provider / multi-forge extension in
[`docs/superpowers/specs/2026-08-15-github-and-multi-provider-design.md`](docs/superpowers/specs/2026-08-15-github-and-multi-provider-design.md).

## How it works

- **tmux** hosts each Claude Code session on the VM. A project can have a
  backward-compatible `default` session plus multiple named sessions.
- Every named session works in its own Git worktree and branch, so concurrent
  Claude processes never share a working tree or index.
- **systemd user service + `loginctl enable-linger`** keep the tmux server alive
  across disconnects and reboots.
- **VS Code Remote-SSH** is the primary client for reviewing diffs and editing;
  `tmux attach` is for answering Claude's questions.
- The **VM is the isolation boundary** — Claude runs natively (Variant A), so it
  can drive `docker compose` directly without docker-in-docker.

## Laptop OS

The laptop-side helpers (`connect.sh`, `bootstrap-remote.sh`) are Bash scripts:

- **macOS / Linux** — run them directly (`./connect.sh`).
- **Windows** — connect with `connect.bat` (double-click) or `.\connect.ps1`
  (PowerShell). For provisioning, run the Bash helper from **Git Bash**
  (`bash ./bootstrap-remote.sh`).

Everything that runs **on the VM** (`bootstrap.sh`, `rd-*`) is Linux-side and
unaffected by the laptop OS.

## Prerequisites

- An Ubuntu LTS VM reachable over SSH by key, with `sudo` that does not prompt
  for a password (bootstrap runs non-interactively). `git` is preinstalled on
  the VM (used to clone this repo).
- Network egress from the VM to apt, npm, `github.com`, `cli.github.com`,
  `gitlab.com` (for the `glab` package), your Git host, `mcp.atlassian.com`,
  and whichever model endpoint your provider uses — `*.googleapis.com` for
  Vertex, `bedrock-runtime.<region>.amazonaws.com` for Bedrock,
  `api.anthropic.com` for the direct API (verify — see the design doc's smoke
  test).
- Credentials for **one** provider: a Vertex-enabled GCP project, or Bedrock
  access (AWS SSO profile, Bedrock API key, or access keys), or an Anthropic
  API key / Claude subscription.

## Setup

1. **Configure** (laptop): copy and edit the config.
   ```bash
   cp rd.env.example rd.env
   # set VM_IP, VM_USER, SSH_KEY
   # set RD_PROVIDER and the block for that provider:
   #   vertex    -> GCP_PROJECT_ID, CLOUD_ML_REGION
   #   bedrock   -> AWS_REGION + one of AWS_PROFILE / AWS_BEARER_TOKEN_BEDROCK / access keys
   #   anthropic -> ANTHROPIC_API_KEY, or leave empty to use a Claude subscription
   ```

2. **Provision the VM — one command from the laptop.** Set `REPO_URL` and a
   read-only `GIT_CLONE_TOKEN` in `rd.env` first (see `rd.env.example` for how to
   mint the token). Then:
   ```bash
   bash bootstrap-remote.sh
   ```
   This clones the repo onto the VM (stripping the token afterwards), copies
   `rd.env`, and runs `bootstrap.sh` on the VM — which installs Node/Claude Code,
   gcloud, `glab`, `gh`, the AWS CLI, Docker, tmux; writes the provider config;
   installs the `rd-*` helpers; installs the Atlassian (Jira) plugin; enables
   systemd/linger durability; and applies SSH hardening + unattended-upgrades.
   Idempotent.

3. **Authorize — one command on the VM.** Connect (`./connect.sh` /
   `.\connect.ps1`), then:
   ```bash
   rd-auth                      # default provider + the forge REPO_URL points at
   rd-auth --provider bedrock   # add a second provider later
   ```
   It logs in to the model provider and the forge, and wires git credentials
   **scoped to that forge host** so GitLab and GitHub never answer for each
   other. Per provider: Vertex finishes a Google ADC URL in your laptop browser;
   Bedrock with an SSO profile runs `aws sso login`; Bedrock with a static
   credential and Anthropic with an API key need no login; an Anthropic
   subscription runs `claude setup-token` and stores the token in
   `~/.config/rd/providers/anthropic.env` (mode 0600). For Jira, start `claude`
   once and trigger a Jira action to complete its OAuth.

## Daily use

The quickest way in is the interactive picker — run it on the VM:

```bash
rd-tui
```

It lists every session, running and stopped, and drives the other helpers:

| key | action |
| --- | --- |
| `↑` `↓` (or `k` `j`) | move |
| `enter` | attach; a stopped session is started first |
| `s` | stop (keeps the worktree and branch) |
| `x` | remove a stopped session's worktree |
| `n` | new session: pick a project, name it, pick feature/bugfix |
| `r` / `q` | refresh / quit |

Attaching replaces `rd-tui` with tmux, so `Ctrl-b` `d` returns you to the shell.
From the laptop, `./connect.sh --tui` (`.\connect.ps1 -Tui`, `connect.bat -Tui`)
opens it straight over SSH.

The same operations are available as plain commands:

```bash
rd-start backend                         # default session in ~/projects/backend
rd-start backend --session new-search    # feature/new-search in its own worktree
rd-start backend --session login-timeout --type bugfix
rd-start backend --session experiment --base origin/main
rd-start backend --session bedrock-try --provider bedrock   # override the default provider

rd-attach backend --session login-timeout    # detach: Ctrl-b then d
rd-stop backend --session login-timeout      # keep the worktree and branch
rd-remove backend --session login-timeout    # remove a clean, stopped worktree
rd-remove backend --session old-fix --delete-branch
rd-list                                    # running sessions
rd-list --all                              # also stopped worktree sessions
rd-list --porcelain --all                  # tab-separated, for scripts
```

Named worktrees live at `~/worktrees/<project>/<session>`. Their default branch
is `feature/<session>`; use `--type bugfix` for `bugfix/<session>`, `--branch`
for an explicit `feature/...` or `bugfix/...` name, and `--base` to override the
starting `HEAD`. Restarting an existing session reuses its worktree and branch,
so `--type` is only needed when it is first created. Project and session names
may contain letters, digits, `_`, and `-`. Tmux metadata prevents ambiguous
legacy names from being attached or stopped as the wrong session.

To clone and start in one command, run `rd-start backend <git-url> --session
new-search`. The laptop helpers can also start and attach directly:

```bash
./connect.sh backend --session new-search
# Windows PowerShell/cmd:
.\connect.ps1 backend -Session new-search -Type feature
connect.bat backend -Session new-search -Type feature
```

List sessions from the laptop without attaching:
```bash
./sessions.sh                      # Windows: sessions.bat  or  .\sessions.ps1
```

Typical loop: start a session, give Claude a task, **close your laptop**. Later,
reconnect (VS Code Remote-SSH for diffs, `rd-attach` for questions), review the
branch Claude committed to, and open a merge request.

## Model providers

The VM's default provider is `RD_PROVIDER` in `rd.env`; `bootstrap.sh` turns
each configured provider into a file under `~/.config/rd/providers/` (mode
0600) and records the default in `~/.config/rd/provider`. A tmux pane is a
login shell, so `~/.profile` sources exactly one of those files at start.

```bash
rd-start backend --provider bedrock   # this session only
rd-list                               # PROVIDER column shows what each session runs on
```

Only the provider *name* is passed to tmux — credentials stay in the 0600 file,
out of `ps` output and out of the tmux session environment.

**A running session's provider cannot change.** The pane's environment is fixed
when it starts, so `rd-start … --provider` against a running session is
rejected; `rd-stop` it first and start it again.

Bedrock has two caveats worth knowing:

- **Pin your models.** Without `ANTHROPIC_DEFAULT_OPUS_MODEL` /
  `…_SONNET_MODEL` / `…_HAIKU_MODEL` in `rd.env`, the `opus` and `sonnet`
  aliases resolve to Claude Code's built-in Bedrock defaults, which may not be
  enabled in your account — the session then quietly falls back to a lower-tier
  model. (`~/.claude/settings.json` ships `"model": "opus[1m]"`, which is a
  Vertex/Anthropic-shaped value.)
- **WebSearch is unavailable on Bedrock.** Sessions there simply do not get
  that tool.

## GitLab and GitHub

Both CLIs are installed and neither is wrapped: `gh` and `glab` read the
repository's own `origin` remote, so in a GitHub checkout `gh pr create` works
and in a GitLab checkout `glab mr create` works, with no per-repo setup.
`rd-auth` logs in to the forge `REPO_URL` points at and scopes git credentials
to that host; run it again with `--forge`/host arguments to add the other one.

Neither merge is one-shot — confirm before moving on:

- **GitLab:** `glab mr merge <iid> --squash` prints "✓ Merged!" while possibly
  only setting `merge_when_pipeline_succeeds`. Check
  `glab api projects/:id/merge_requests/<iid>` for `state: merged`.
- **GitHub:** `gh pr merge <n> --squash` queues the merge when required checks
  are pending, and branch protection can reject a merge the CLI reported as
  submitted. Check `gh pr view <n> --json state,mergedAt`.

## VS Code (Remote-SSH)

Use VS Code as the client for browsing diffs and editing files on the VM.

1. Install the **Remote - SSH** extension (`ms-vscode-remote.remote-ssh`).
2. Add the VM to your SSH config (`~/.ssh/config`, or `%USERPROFILE%\.ssh\config`
   on Windows):
   ```
   Host dev-vm
       HostName <vm-ip>
       User <vm-user>
       IdentityFile ~/.ssh/<key>.pem
   ```
3. `F1` → **Remote-SSH: Connect to Host…** → pick `dev-vm`.
4. Configure automatic attach once for each project, from a VM terminal:
   ```bash
   rd-vscode-init ~/projects/backend
   ```
   Commit the resulting `.vscode/tasks.json` if teammates should inherit it.
   Run this before creating named worktrees, or run it separately in an already
   existing worktree.
5. **File → Open Folder…** and open the exact working tree:
   `/home/<vm-user>/projects/backend` for `default`, or
   `/home/<vm-user>/worktrees/backend/login-timeout` for that named session.
6. On the first open, trust the workspace and allow automatic tasks. VS Code
   opens a dedicated terminal and runs `rd-attach-here`, which reads tmux
   metadata and attaches the matching session. Review changes in **Source
   Control** (`Ctrl+Shift+G`).

VS Code installs its server component on the VM automatically on first connect.
If no matching session is running, the task terminal explains how to start one.

## Syncing Claude memory

Claude Code stores per-project memory under
`~/.claude/projects/<encoded-absolute-path>/memory/`, keyed by the project's
**absolute path** — which differs between the laptop and the VM. `sync-memory.sh`
maps the paths and copies the `memory/` folder across:

```bash
./sync-memory.sh push <project-name>   # laptop -> VM (seed the VM with your memory)
./sync-memory.sh pull <project-name>   # VM -> laptop (bring back memory made on the VM)
```

`<project-name>` is the project folder's basename (e.g. `project1`);
the VM path defaults to `/home/<VM_USER>/projects/<project-name>`. Files are
copied/overwritten, not merged — run `push` to seed, `pull` to retrieve.

For knowledge you want to be portable by design, prefer committing it to
`CLAUDE.md` / `AGENTS.md` in the repo: that travels with `git` and is
path-independent.

## Security

The VM is treated as a **disposable sandbox**. Because Claude runs autonomously
with Docker access, it is effectively root-equivalent *inside* the VM — so
protection lives at the VM boundary:

- key-only SSH, no root login (applied by bootstrap);
- automatic security updates;
- VM snapshots + a Git remote as source of truth for recovery;
- **recommended next step:** enable the egress allowlist in
  [`hardening/egress-allowlist.nft`](hardening/egress-allowlist.nft) to bound
  what the agent can reach. Test before enabling on boot.

Each teammate uses their **own VM** and their **own** provider login (`gcloud`
ADC, AWS SSO, or an Anthropic token), keeping the audit trail clean. Provider
credentials live in `~/.config/rd/providers/*.env` at mode 0600 and are never
written to a tracked file.

## Layout

```
bootstrap.sh                 # idempotent VM installer (run on the VM)
bootstrap-remote.sh          # laptop-side: clone repo onto the VM + copy rd.env
connect.sh / .ps1 / .bat     # laptop-side connect (+ optional start/attach, --tui)
sessions.sh / .ps1 / .bat    # laptop-side: list VM sessions without attaching
sync-memory.sh               # laptop-side: sync Claude per-project memory <-> VM
bin/rd-tui                   # interactive session picker (wraps the rd-* helpers)
bin/rd-auth                  # one-command authorization: provider + forge + git author
bin/rd-vscode-init           # add a project-scoped automatic attach task
bin/rd-attach-here           # attach using the opened worktree path
rd.env.example               # config template (copy to rd.env)
bin/rd-*                     # tmux session helpers (installed to ~/.local/bin)
systemd/tmux-claude.service  # persistent tmux user service
hardening/                   # sshd, unattended-upgrades, egress allowlist
tests/                       # stub-driven tests for the rd-* helpers
docs/superpowers/specs/      # design documents
docs/superpowers/plans/      # implementation plans
```
