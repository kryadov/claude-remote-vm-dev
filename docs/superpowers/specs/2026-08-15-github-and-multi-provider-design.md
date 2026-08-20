# GitHub alongside GitLab, and Bedrock / Anthropic API alongside Vertex

Design document. Extends
`2026-08-15-remote-claude-code-vm-design.md`, which assumes a single forge
(GitLab) and a single model provider (GCP Vertex AI). Read that first — this
document only describes what changes.

## 1. Problem

The VM tooling hard-codes two choices made when the repo was written:

- **One forge.** `bootstrap.sh` installs `glab`; `rd-auth` runs `glab auth
  login` and points git's *global* credential helper at `glab`;
  `bootstrap-remote.sh` builds its first-clone URL as
  `https://oauth2:<token>@…`, which is GitLab's scheme. A GitHub repository
  cannot be cloned, pushed, or reviewed from the VM.
- **One model provider.** `bootstrap.sh` writes `CLAUDE_CODE_USE_VERTEX=1` and
  the Vertex project/region into `~/.profile`. There is no way to run a session
  against Amazon Bedrock or the direct Anthropic API, and no way to run two
  sessions on different providers at once.

Both are needed inside the perimeter: repositories live on both GitLab and
GitHub (including GitHub Enterprise Server), and model access differs per
team — some have Vertex, some have Bedrock, some have an Anthropic API key or
a Claude subscription.

## 2. Goals and non-goals

**Goals**

- Both forge CLIs present on every VM; the forge in use is resolved per
  repository from its git remote, with no wrapper command in between.
- Any GitHub host, `github.com` and GitHub Enterprise Server alike.
- Three model providers — Vertex, Bedrock, direct Anthropic API — with a
  default in `rd.env` and a per-session override.
- All authorization stays in `rd-auth`; `bootstrap.sh` stays non-interactive.
- No secret ever appears in a tracked file, a process argument list, or a tmux
  session environment.

**Non-goals**

- An `rd-forge` / `rd-mr` abstraction over `gh` and `glab` (see §3, decision 3).
- Changing the model *within* a running session. Provider env vars are read by
  the login shell when the tmux pane is created; changing them means a new
  session. `rd-start` detects and rejects the mismatch rather than silently
  ignoring it.
- Per-project provider defaults. The default is per VM, the override per
  session.

## 3. Approved decisions

These were settled in brainstorming and are not re-opened here.

1. **Dynamic with defaults.** Both forge CLIs are installed. The forge is
   resolved per repository from its git remote. The model provider has a
   default in `rd.env`, overridable per session
   (`rd-start <project> --provider bedrock`) — so provider env vars must be
   injectable into the tmux session, not only into `~/.profile`.
2. **All four auth paths in `rd-auth`**, alongside the existing Vertex ADC:
   Bedrock via AWS SSO (preferred — no static keys), Bedrock via static
   credentials, Anthropic via `ANTHROPIC_API_KEY`, and Anthropic via
   subscription OAuth (`claude setup-token`). Forge logins: `glab auth login`,
   `gh auth login` + `gh auth setup-git`.
3. **No forge wrapper.** Bootstrap installs both CLIs, `rd-auth` logs in, and
   the docs explain remote-based detection plus the MR-vs-PR merge gotchas.
   `gh` and `glab` differ enough that a wrapper would leak.
4. **Any GitHub host**, `github.com` and GitHub Enterprise Server alike; the
   host comes from the remote, `gh auth login --hostname <host>`. Symmetric
   with the existing self-hosted GitLab handling, and required inside the
   perimeter.
5. **One `GIT_CLONE_TOKEN`**, with `bootstrap-remote.sh` branching on the host
   in `REPO_URL` to build the credential URL (GitLab `oauth2:<token>@`, GitHub
   `x-access-token:<token>@`). The token is still stripped from the stored
   remote after the first clone.

## 4. Provider layer

### 4.1 Why the env vars cannot simply be exported

`tmux.conf` sets no `default-command`, so tmux starts each pane's shell as a
**login shell**, which sources `~/.profile`. That is the only reason the
current Vertex block works at all: the tmux *server* is started by a systemd
user service, which never reads `~/.profile`, and a new session's environment
is copied from the server's global environment, not from the `rd-start`
process. Exporting a variable in `rd-start` therefore does *not* reach the
session.

Three approaches were considered — passing every provider variable through
`tmux new-session -e`, wrapping `claude` in a shim, and the layered file
approach below. The first puts secrets on a command line visible in `ps` and
duplicates provider logic outside `~/.profile`; the second loses the provider
whenever anything other than the original `claude` process runs in the pane
(a manual restart after exit, a second window, a subshell). The layered
approach was chosen.

### 4.2 Layout

`bootstrap.sh` creates, from values in `rd.env`:

```
~/.config/rd/provider              # one line: the default provider name
~/.config/rd/providers/vertex.env  # mode 0600, plain `export` lines
~/.config/rd/providers/bedrock.env
~/.config/rd/providers/anthropic.env
```

A provider file is only written when its required `rd.env` values are present,
so a VM with Vertex alone has one file and `--provider bedrock` fails with a
clear message rather than starting a session that cannot reach a model.

The `~/.profile` block shrinks to a switch. Marker comments change from
`remote-dev vertex` to `remote-dev provider`; bootstrap strips **both** marker
pairs before appending, so re-running it on an existing VM migrates cleanly.

```sh
# >>> remote-dev provider >>>
export PATH="$HOME/.local/bin:$PATH"
RD_PROVIDER="${RD_PROVIDER:-$(cat "$HOME/.config/rd/provider" 2>/dev/null || echo vertex)}"
if [ -r "$HOME/.config/rd/providers/$RD_PROVIDER.env" ]; then
  . "$HOME/.config/rd/providers/$RD_PROVIDER.env"
fi
export RD_PROVIDER
# <<< remote-dev provider <<<
```

The `${RD_PROVIDER:-…}` default is what makes the override work: a value
already in the environment wins over the file.

### 4.3 Provider file contents

Variable names verified against the Claude Code documentation, not recalled.

| Provider    | Variables                                                                                            |
| ----------- | ---------------------------------------------------------------------------------------------------- |
| `vertex`    | `CLAUDE_CODE_USE_VERTEX=1`, `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION`                          |
| `bedrock`   | `CLAUDE_CODE_USE_BEDROCK=1`, `AWS_REGION`, plus one auth path (below) and optional model pins         |
| `anthropic` | `ANTHROPIC_API_KEY`, **or** `CLAUDE_CODE_OAUTH_TOKEN` for the subscription path                       |

Bedrock auth paths, in the order `rd-auth` prefers them:

1. **AWS SSO** — `AWS_PROFILE=<profile>`; `aws sso login --profile <profile>`
   refreshes it. No long-lived secret on the VM.
2. **Bedrock API key** — `AWS_BEARER_TOKEN_BEDROCK`. A single credential, no
   AWS credential chain.
3. **Static keys** — `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
   (+ `AWS_SESSION_TOKEN`). Supported, discouraged.

Two Bedrock facts that must be reflected in the config and the docs:

- **Model aliases need pinning.** Without `ANTHROPIC_DEFAULT_OPUS_MODEL` /
  `…_SONNET_MODEL` / `…_HAIKU_MODEL`, `opus` and `sonnet` resolve to Claude
  Code's built-in Bedrock defaults, which may not be enabled in the account —
  the session then falls back to a lower-tier model at startup. `rd.env`
  therefore carries optional pin values, and `~/.claude/settings.json`'s
  `"model": "opus[1m]"` is documented as a Vertex/Anthropic-shaped value.
- **WebSearch is unavailable on Bedrock.** Documented, not worked around.

### 4.4 `rd-start --provider`

- Resolves the provider: the flag, else `~/.config/rd/provider`, else `vertex`.
- Rejects a name with no `providers/<name>.env`, listing what is configured.
- For a **new** session, passes exactly one variable across the tmux boundary:
  `tmux new-session … -e RD_PROVIDER=<name>`. Secrets stay in the 0600 file and
  never reach `ps` output or the tmux session environment.
- Records the resolved name as the `@rd_provider` tmux user option, alongside
  the existing `@rd_project` / `@rd_session` / `@rd_worktree`.
- For an **existing** session, a `--provider` that differs from the stored
  `@rd_provider` is an error naming both values and pointing at `rd-stop` —
  the pane's environment was fixed when it was created, so silently accepting
  the flag would be a lie.

`rd-list` gains a `PROVIDER` column, appended last in `--porcelain` so the
column order of existing consumers is unchanged; `rd-tui` reads and renders it.

### 4.5 `rd-auth`

`rd-auth [--provider <name>] [--forge github|gitlab] [<forge-host>]` keeps its
"one command for every one-time authorization" role and becomes provider-aware.

Provider step, on the resolved provider only:

| Provider                  | Action                                                                    |
| ------------------------- | ------------------------------------------------------------------------- |
| `vertex`                  | `gcloud auth application-default login --no-launch-browser` (unchanged)   |
| `bedrock`, SSO            | `aws sso login --profile <AWS_PROFILE>`, skipped if the profile is valid  |
| `bedrock`, key/static     | verify the variables are present in the provider file; nothing to log in  |
| `anthropic`, API key      | verify `ANTHROPIC_API_KEY` is present                                     |
| `anthropic`, subscription | run `claude setup-token`, then write the pasted token to `anthropic.env`  |

The subscription path is the only one that produces a secret at auth time.
`rd-auth` writes it to `~/.config/rd/providers/anthropic.env` at mode 0600 —
never to `rd.env`, which is copied from the laptop, and never echoed back.

Forge step:

- Resolve the forge: `--forge`, else `FORGE` in `rd.env`, else the host (a name
  containing `github` or `gitlab` names its own forge — this covers
  `gitlab.example.com` as well as `gitlab.com`), else ask. With no TTY to ask,
  fail naming `--forge` rather than guessing.
- GitLab: `glab auth login --hostname <host>`, then a **host-scoped**
  credential helper.
- GitHub: `gh auth login --hostname <host>`, then `gh auth setup-git
  --hostname <host>`, which writes its own host-scoped helper.

Two details the live GitLab run forced, both now covered by tests:

- **Check the login scoped, and without a pipeline.** `glab auth status` exits
  non-zero when *any* configured instance fails — a stale `gitlab.com` entry is
  enough — so `glab auth status | grep -q "$host"` under `set -o pipefail`
  reports "not logged in" for a host that is perfectly fine, and re-runs the
  login. Use `glab auth status --hostname "$host"`, mirroring the `gh` branch.
- **Follow `REPO_URL`'s scheme.** Git matches a credential helper by scheme as
  well as host, so an `https://`-scoped helper is never consulted for an
  `http://` remote and the clone dies asking for a username. `https` stays the
  default; an `http://` `REPO_URL` switches both the helper scope and the
  token-creation URL printed to the user.

The credential helper must be host-scoped, not global:

```sh
git config --global credential."https://$host".helper '!glab auth git-credential'
```

The current global `credential.helper='!glab auth git-credential'` would answer
for GitHub hosts too and break every GitHub push. `rd-auth` detects that exact
global value on an already-provisioned VM, unsets it, and re-adds it scoped —
the migration is automatic and idempotent.

## 5. Forge layer

### 5.1 Installing `gh`

GitHub publishes a signed apt repository, so `gh` follows the `gcloud` pattern
rather than the `glab` fallback:

```sh
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=…] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list
```

`glab` keeps its versioned-`.deb` install (no signed repo exists). The **AWS CLI
is not in the Ubuntu 24.04 archive at all** — there is no candidate even with
`universe` enabled — so it comes from AWS's own versioned zip, the same
fetch-an-artifact fallback `glab` uses, warning and continuing on failure. Only
the Bedrock SSO path needs it.

### 5.2 First clone (`bootstrap-remote.sh`)

`GIT_CLONE_TOKEN` stays a single key. The credential prefix branches on the
resolved forge:

| Forge  | Clone URL                                        |
| ------ | ------------------------------------------------ |
| GitLab | `https://oauth2:<token>@<host>/…`                |
| GitHub | `https://x-access-token:<token>@<host>/…`        |

Resolution is the same three-step rule as `rd-auth` (`FORGE` in `rd.env`, then
the host, then GitLab as the historical default), so a self-hosted host only
has to be declared once. The token is stripped from the stored remote after
the first clone, exactly as today.

### 5.3 Day-to-day use, and the merge gotchas

No wrapper is added. Both CLIs read the repository's `origin` remote, so in a
GitHub checkout `gh pr create` works and in a GitLab checkout `glab mr create`
works, with no per-repo configuration. The docs state this explicitly and
carry the merge caveats for both:

- **GitLab** (already documented in `AGENTS.md`): `glab mr merge --squash`
  prints "✓ Merged!" while only setting `merge_when_pipeline_succeeds`; the
  real state must be confirmed through the API.
- **GitHub**: `gh pr merge --squash` on a repo with required checks queues the
  merge (`--auto`) instead of merging; branch protection can also reject a
  merge that the CLI reports as submitted. Confirm with
  `gh pr view <n> --json state,mergedAt` before moving on.

## 6. Error handling

| Situation                                            | Behavior                                                              |
| ---------------------------------------------------- | --------------------------------------------------------------------- |
| `--provider` names a provider with no config file     | `rd-start` exits 2, listing the configured providers                   |
| `--provider` differs from a running session's         | `rd-start` exits 1, naming both and pointing at `rd-stop`              |
| No provider config at all, and no `--provider`        | `rd-start` starts the session anyway and records no provider — a VM provisioned before this existed must keep working |
| `~/.config/rd/provider` missing but providers exist   | `~/.profile` falls back to `vertex`; `rd-start` reports it explicitly  |
| Provider file missing at pane start                   | the `[ -r … ]` guard skips it; `claude` then fails with its own error  |
| `rd.env` has no provider values at bootstrap          | no provider file is written; `rd-auth` says which values are missing   |
| Forge cannot be resolved                              | `rd-auth` prompts; `bootstrap-remote.sh` defaults to GitLab and warns  |
| Old global `glab` credential helper found             | `rd-auth` unsets it and re-adds it host-scoped                         |

## 7. Testing

Existing suites (`test-rd-sessions.sh`, `test-rd-tui.sh`, `test-rd-auth.sh`,
`test-connect.ps1`) must keep passing. New coverage:

- **`tests/test-rd-provider.sh`** — `rd-start` resolves the default, honors
  `--provider`, passes `-e RD_PROVIDER=` to tmux, records `@rd_provider`,
  rejects an unknown provider, and rejects a mismatch against a running
  session. `rd-list` emits the provider column.
- **`tests/test-rd-auth.sh`** (extended) — the Bedrock SSO path calls
  `aws sso login --profile`; the subscription path writes
  `CLAUDE_CODE_OAUTH_TOKEN` to a 0600 file; a GitHub host runs `gh auth login`
  + `gh auth setup-git` and *not* `glab`; a GitLab host writes a host-scoped
  credential helper; a legacy global helper is migrated.
- **`tests/stubs/tmux`** — records `-e` pairs from `new-session` and reports
  `@rd_provider` in `list-sessions`.

Two smoke layers sit above the stub suites, because neither `bootstrap.sh` nor
the login-shell mechanism can be proven with stubs:

- **Container run** — `bootstrap.sh` end to end in a throwaway `ubuntu:24.04`
  container with a `sudo` passthrough shim: the apt/artifact installs, the
  provider files, the `~/.profile` migration from the old `remote-dev vertex`
  block, idempotency on re-run, and a real login shell exporting the right
  provider. Everything needing a running init (`loginctl`, `systemctl --user`)
  cannot be covered there and stops the run at that section.
- **Live VM** — the real gate: bootstrap, `rd-auth`, then one session per
  configured provider, checking `claude` reaches a model in each and that a
  GitHub and a GitLab checkout can both push.

The container layer already caught two defects the stub suites could not: a
bare `"$USER"` aborting the script under `set -u` when run through
`ssh host cmd` (which is exactly how `bootstrap-remote.sh` invokes it), and an
`apt-get install awscli` that can never succeed on Ubuntu 24.04.

## 8. Files touched

| File                          | Change                                                              |
| ----------------------------- | ------------------------------------------------------------------- |
| `rd.env.example`              | `RD_PROVIDER`, `FORGE`, Bedrock and Anthropic blocks, model pins     |
| `bootstrap.sh`                | provider files + switch block; install `gh` and `awscli`             |
| `bootstrap-remote.sh`         | forge-aware clone credential prefix                                  |
| `bin/rd-start`                | `--provider`, tmux `-e`, `@rd_provider`, mismatch check              |
| `bin/rd-list`                 | provider column (human + porcelain)                                  |
| `bin/rd-tui`                  | parse and render the provider column                                 |
| `bin/rd-auth`                 | provider-aware auth, forge resolution, host-scoped credential helper |
| `tests/stubs/tmux`            | `-e` recording, `@rd_provider` in `list-sessions`                    |
| `tests/test-rd-provider.sh`   | new                                                                  |
| `tests/test-rd-auth.sh`       | extended                                                             |
| `README.md`, `AGENTS.md`      | provider selection, both forges, merge gotchas, layout               |

## 9. Compatibility

An existing VM upgrades by re-running `bootstrap.sh` and `rd-auth`:

- the `remote-dev vertex` block in `~/.profile` is replaced by the
  `remote-dev provider` switch, which resolves to `vertex` when `rd.env` has
  only the Vertex values — the default is unchanged;
- the global `glab` credential helper is migrated to a host-scoped one;
- sessions started before the upgrade have no `@rd_provider`; `rd-list` shows
  `-` for them, and because a pane's environment is fixed at creation, the
  first `rd-start --provider` against such a session records the name rather
  than reporting a mismatch — there is nothing to disagree with.

A VM where only the `rd-*` helpers were updated — `bootstrap.sh` not yet
re-run, so `~/.config/rd` does not exist — keeps working unchanged: `rd-start`
starts sessions with no provider recorded and the old `~/.profile` Vertex block
still supplies the environment. Only an explicit `--provider` fails there, and
it fails with a message naming what to run.
