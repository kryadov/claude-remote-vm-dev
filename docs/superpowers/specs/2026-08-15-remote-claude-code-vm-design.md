# Design: Remote Claude Code Sessions on a VM

- **Date:** 2026-08-15
- **Status:** design approved, ready for implementation
- **Audience:** developers who want to run long-lived Claude Code sessions
  server-side and share the setup with teammates

## 1. Context and goal

Today Claude Code runs locally on the laptop. The goal is to move session
execution to a server-side VM so that:

- sessions **keep running in the background on the VM while the laptop is off**;
- from the laptop you can **connect, review changed files, answer questions,
  finish a session, and start a new one**;
- everything is **secure** (the VM lives inside the organization's perimeter);
- the setup can be **shared with teammates**.

Access to Claude models is provided **through GCP Vertex AI**
(`CLAUDE_CODE_USE_VERTEX=1`), not the direct Anthropic API.

### Off-the-shelf options
Anthropic offers **Claude Code on the web / remote agents** (cloud sandboxes
hosted by Anthropic). That is managed cloud **outside the organization's
perimeter**, so it does not fit the "VM inside the perimeter" requirement. We
build a self-hosted equivalent from standard building blocks (SSH, tmux,
systemd, VS Code Remote-SSH, gcloud/Vertex).

## 2. Scope

**In scope:** provisioning a single personal VM, session durability, Vertex
authentication, autonomous Claude mode, client access and change review,
developer integrations (GitLab CLI, Jira/Confluence plugin), baseline security
hardening, and a bootstrap script for sharing.

**Out of scope (intentionally deferred):** strict egress firewall with an
allowlist (a separate recommended step after the base install); multi-user on a
single VM; a headless orchestrator with a web dashboard; containerizing Claude
(see the Variant A decision below).

## 3. Key decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Interaction model | tmux (background) + VS Code Remote-SSH (client) | Durability + familiar file review/editing |
| 2 | Autonomy | Session keeps running with the laptop off | Core requirement |
| 3 | Isolation topology | **Variant A**: Claude runs natively on the VM, VM = isolation boundary | The project needs `docker compose`; Claude-in-a-container would require docker-in-docker / mounting the docker socket (= host root), defeating the point of isolation. CI avoids privileged docker-in-docker for the same reason |
| 4 | Vertex authentication | User ADC (`gcloud auth application-default login`) | Already used locally; no SA keys; clean per-identity audit when shared |
| 5 | Permission level | Full `--dangerously-skip-permissions` | The VM is a dedicated sandbox; the session must not block waiting for the user |
| 6 | Egress firewall | Separate step after the base | Faster to stand up the base; a strict allowlist needs iteration |

## 4. Target environment

- A private-cloud VM: private IP, key-only SSH, and sudo for the login user
  (`bootstrap.sh` runs non-interactively, so sudo must not prompt).
- A current Ubuntu LTS release, sized to run the project's `docker compose`
  stack and a Claude session at the same time.
- Preinstalled: `tmux`, `git`, `python3`. To install: `gcloud`, Node.js/npm,
  `claude` (Claude Code CLI), `glab` (GitLab CLI), `docker`. The repo is delivered
  to the VM via `git clone` (not file copy).
- **Egress verified open** (validate on each new VM): `*.googleapis.com`
  (Vertex/OAuth), npm, `dl.google.com`, nodesource, apt, `github.com`,
  `gitlab.com` (for the `glab` package), the internal Git host, and
  `mcp.atlassian.com` (Jira plugin) are reachable.
- GCP: a Vertex-enabled project; Vertex region `global`.

### Configuration placeholders
These are the only environment-specific values; keep them in `rd.env` (see
implementation), never hard-code them:

| Placeholder | Meaning |
|-------------|---------|
| `<VM_IP>` | Private IP of the VM |
| `<VM_USER>` | SSH login user (e.g. `ubuntu`) |
| `<SSH_KEY>` | Path to the private key, e.g. `~/.ssh/<key>.pem` |
| `<GCP_PROJECT_ID>` | Vertex-enabled GCP project id |
| `<CLOUD_ML_REGION>` | Vertex region, e.g. `global` |
| `<PROJECT>` | Short name of a code project/session |

## 5. Architecture

```
Laptop (VS Code + SSH)                 Remote VM (private, inside perimeter)
─────────────────────                  ────────────────────────────────────
 VS Code Remote-SSH  ──── SSH ───────▶  sshd (key-only)
 ssh + tmux attach   ──── SSH ───────▶  tmux: claude-<PROJECT>[--<SESSION>]  ← systemd linger
                                             └─ claude --dangerously-skip-permissions
                                                   │  (Vertex via ADC)
                                                   ├─ git (branches, checkpoint commits)
                                                   └─ docker compose (project services)
                                                        │
                                        egress ─────────┴─────▶ *.googleapis.com (Vertex)
                                                                Git host / npm / registries
```

The laptop can be shut down at any time — the tmux-hosted Claude process keeps
running on the VM. On reconnect: VS Code Remote-SSH for files/diffs,
`tmux attach` to answer Claude's questions.

## 6. Components

### 6.1 Session durability
- Claude Code runs inside **tmux**. The backward-compatible default session is
  `claude-<PROJECT>`; named sessions use `claude-<PROJECT>--<SESSION>`.
  Tmux user-option metadata disambiguates legacy default project names that
  contain the `--` separator.
- Each named session uses an isolated Git worktree at
  `~/worktrees/<PROJECT>/<SESSION>` and a `feature/<SESSION>` or
  `bugfix/<SESSION>` branch.
- Surviving reboot and running with no logged-in user:
  `loginctl enable-linger <VM_USER>` + a **systemd user service** that recreates
  the desired tmux sessions on boot.
- Helper scripts `rd-start`, `rd-attach`, `rd-list`, `rd-stop`, and `rd-remove`
  manage default and named sessions. `rd-vscode-init` adds a project-scoped
  automatic task; `rd-attach-here` resolves the session from the opened worktree.

### 6.2 Vertex authentication
- `gcloud auth application-default login --no-launch-browser` (headless VM →
  URL/device flow, once per user).
- Env in `~/.profile` / `~/.bashrc`:
  ```
  export CLAUDE_CODE_USE_VERTEX=1
  export ANTHROPIC_VERTEX_PROJECT_ID=<GCP_PROJECT_ID>
  export CLOUD_ML_REGION=<CLOUD_ML_REGION>
  ```
- ADC file `~/.config/gcloud/application_default_credentials.json` → mode `600`.
- No service-account keys.

### 6.3 Autonomous Claude mode
- Launch: `claude --dangerously-skip-permissions` (tools auto-approved; the
  session never blocks waiting for the user).
- `~/.claude/settings.json` mirrors the local one (model, effort level, allowed
  permissions).
- Guardrail against unwanted changes: Claude works on a **dedicated git branch**
  and makes frequent checkpoint commits; review via diff before merge.

### 6.4 Client and change review
- **VS Code Remote-SSH** to `<VM_IP>` is the primary client: Source Control /
  diff of changed files, editing, integrated terminal.
- Answering Claude's questions: `rd-attach <PROJECT> [--session <SESSION>]` (in
  the VS Code terminal or a separate `ssh`). A project can opt into automatic
  attach on folder open with `rd-vscode-init <repo-path>`.
- Flow: Claude commits to a branch → review `git diff` / VS Code → open a merge
  request on the Git host.

### 6.5 Security / Ubuntu hardening

**Threat model.** Once Claude is autonomous and has Docker access, it is
effectively **root-equivalent inside the VM** (the docker group can mount host
root). Therefore protection is built **at the VM boundary**, not inside it; the
VM is treated as disposable.

Baseline (in bootstrap):
- **SSH:** key only, `PasswordAuthentication no`, `PermitRootLogin no`, and where
  possible restrict the source IP to a management range.
- **Passphrase on the private key** + ssh-agent (in case the laptop is stolen).
- **`unattended-upgrades`** for automatic security updates.
- **Minimal exposed services:** only sshd listens, on the private IP.
- **Secrets:** ADC file `600`; the project `.env` stays out of git.
- **Recovery via disposability:** periodic VM snapshots + a git remote as
  source of truth. If broken/compromised → recreate from image.
- Keep AppArmor enabled (default); `auditd` is optional.

Deferred (recommended) step:
- **Egress firewall with an allowlist** (nftables): permit only
  `*.googleapis.com`, apt, npm, the Git host, and required registries — deny the
  rest. Bounds both the autonomous agent's reach and secret-exfiltration risk.

### 6.6 Developer integrations
Delivered/installed by bootstrap so Claude can run the full ticket→MR lifecycle:

- **GitLab CLI (`glab`)** — create merge requests, watch pipelines. It also
  provides git credentials for `clone`/`push` via
  `git config --global credential.helper '!glab auth git-credential'`. Authorize
  once with `glab auth login --hostname <git-host>`.
- **Jira/Confluence** — the official **`atlassian` plugin** (from the
  `anthropics/claude-plugins-official` marketplace), which registers an HTTP MCP
  server at `mcp.atlassian.com` with OAuth. Skills use
  `mcp__plugin_atlassian_atlassian__*` tools, so the *plugin* is required (not a
  bare `claude mcp add`). Authorized on first use via a browser URL.
- **Repo delivery** — `git clone` on the VM (git is preinstalled). The first
  clone needs git auth (SSH key on GitLab or an HTTPS token); afterwards the
  `glab` credential helper handles it.

### 6.7 Sharing with teammates
- **`bootstrap.sh`** — idempotent script: installs Node.js/Claude Code, gcloud,
  Docker, tmux; configures `loginctl enable-linger` and the systemd user service;
  installs `~/.claude/settings.json`, env vars, and the `rd-*` helpers; applies
  SSH hardening.
- **`README.md` / runbook** — how to get a VM, log in to ADC, start and reconnect
  to a session.
- Each teammate uses **their own VM** (from an image/snapshot) and **their own**
  `gcloud auth application-default login` under their personal account → clean
  audit.
- Optional: **cloud-init** to auto-provision the VM from the bootstrap.

## 7. User workflow

1. Connect (VS Code Remote-SSH or `ssh`), then run `rd-start <PROJECT>` for the
   default session or `rd-start <PROJECT> --session <SESSION>` for an isolated
   named worktree.
2. Give Claude a task; answer the first questions if needed.
3. **Close the laptop / disconnect** — tmux + Claude keep running on the VM.
4. Reconnect later: review the diff in VS Code, `rd-attach` to answer accumulated
   questions and adjust.
5. Finish: merge the branch / open a merge request, `rd-stop` or start a new
   session.

## 8. Verification plan (smoke test)

1. `git clone` the repo on the VM; run `bootstrap.sh`; check versions of `node`,
   `claude`, `gcloud`, `glab`, `docker`.
2. `gcloud auth application-default login --no-launch-browser`; confirm Claude
   responds via Vertex.
3. `glab auth login`; confirm `glab mr list` works against the Git host. Confirm
   the `atlassian` plugin authorizes and a Jira tool returns an issue.
4. Start two named sessions in one project, give each a task, and verify their
   branches and worktrees are isolated.
5. **Disconnect, emulate laptop shutdown, wait, reconnect** — confirm the session
   kept working.
6. Confirm `docker compose up` launched by Claude brings up the project services.
7. Confirm reboot survival: `sudo reboot`, then the tmux session is alive after
   boot.

## 9. Risks and open questions

- **Full autonomy = broad privileges.** Mitigated by the disposable VM, git
  checkpoints, and the (deferred) egress allowlist.
- **ADC token on the VM** — if the VM is compromised it grants Vertex access
  under the user's account. Mitigated by SSH hardening and disposability; rotate
  via re-running `gcloud auth`.
- **Egress currently open** — a conscious decision; close it with the allowlist
  in step 2.
- **Confirm with the platform/network team:** the VM snapshot policy and the
  permitted management range for SSH restriction.

## Appendix A. Environment variables
```
CLAUDE_CODE_USE_VERTEX=1
ANTHROPIC_VERTEX_PROJECT_ID=<GCP_PROJECT_ID>
CLOUD_ML_REGION=<CLOUD_ML_REGION>
```

## Appendix B. Reference commands
```bash
# connect to the VM
ssh -i <SSH_KEY> <VM_USER>@<VM_IP>

# session management
rd-start <PROJECT> [--session <SESSION>] [--type feature|bugfix]
rd-attach <PROJECT> [--session <SESSION>]
rd-list
rd-stop <PROJECT> [--session <SESSION>]
rd-remove <PROJECT> --session <SESSION> [--delete-branch]
rd-vscode-init <repo-path>
```
