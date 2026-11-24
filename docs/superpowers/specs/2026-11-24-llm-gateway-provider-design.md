# An LLM gateway as a model provider

Design document. Extends `2026-08-15-github-and-multi-provider-design.md`; read
that first — this document only describes what changes.

## 1. Problem

Claude traffic is increasingly routed through an Anthropic-compatible gateway
(LiteLLM and similar) rather than straight to Vertex, Bedrock or the Anthropic
API: one place for keys, budgets and model routing. Claude Code supports this
with `ANTHROPIC_BASE_URL` plus `ANTHROPIC_AUTH_TOKEN`.

rd knew three providers, each written by `bootstrap.sh` from `rd.env`. A
gateway could only be hand-written into `~/.config/rd/providers/`, where
`rd-auth` rejected it as an unknown provider and a rebuilt VM lost it. On
laptops the same setup tends to live in a wrapper script that unsets the Vertex
variables before starting `claude` — a hint at the trap in §3.

## 2. Decisions

| Question | Decision |
| --- | --- |
| Provider name | `gateway`: the role, not one product. |
| What enables it | `ANTHROPIC_BASE_URL` in `rd.env`, the way `AWS_REGION` enables Bedrock. |
| Credential | `ANTHROPIC_AUTH_TOKEN`, sent as `Authorization: Bearer` — what LiteLLM virtual keys use. `ANTHROPIC_API_KEY` stays the direct-API provider's. |
| Optional settings | `ENABLE_TOOL_SEARCH`, `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS` are written when set: named keys, like the Bedrock model pins, not a free-form passthrough. |
| Quoting | Gateway values are single-quoted in `gateway.env` (`'` spelled `'\''`); `rd-auth` undoes exactly that. The `rd.env` template single-quotes the key as well, because `rd.env` is sourced. A key such as `sk-a&b$c` then reaches the shell and the check unchanged. |
| Inherited provider state | `~/.profile` unsets every provider switch and credential Claude reads before sourcing the selected file — for every provider, not just the gateway (§3). General AWS credentials and gcloud are kept. |
| Which file a pane loads | `rd-start` passes the session's provider name — explicit or the VM default — with `tmux new-session -e RD_PROVIDER=…`, as §4.4 of the multi-provider design always intended. `rd-restart` refuses a session whose provider file has been removed. |
| `rd-auth` | Nothing to log in to. A URL without a scheme is refused before anything is sent; plain `http://` gets a warning. Then `GET <url>/v1/models` with the key fed to `curl -K -` on stdin; only a 2xx counts, so a redirect to https or to an SSO page does not pass. No HTTP answer at all is reported as such, with curl's reason, not blamed on the key; a missing token is said out loud. Any refusal warns and the forge login still runs. |
| `~/.claude/settings.json` | Untouched, as for every provider; the docs warn about Vertex-shaped model pins and the telemetry default (§4). |

What the optional settings do, as Claude Code uses them:
`ENABLE_TOOL_SEARCH=true` keeps MCP tool search on, which Claude otherwise turns
off for a non-Anthropic base URL; `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`
makes Claude read the model list from the gateway's `/v1/models` at start;
`CLAUDE_CODE_MAX_CONTEXT_TOKENS` tells Claude the models' real context window,
which it cannot learn from a gateway.

## 3. Inherited provider state

Claude Code checks `CLAUDE_CODE_USE_VERTEX` and `CLAUDE_CODE_USE_BEDROCK` before
it looks at `ANTHROPIC_BASE_URL`, and in Claude-API mode it honours an
`ANTHROPIC_BASE_URL` for any credential it has. A pane's environment comes from
the tmux server's global environment — frozen when the server started, which
is a login shell's whole environment whenever someone started it by hand — and
from `~/.bashrc`, both before `~/.profile` reaches the provider switch. Two
failures follow, one in each direction:

- A server started from a Vertex shell hands every pane
  `CLAUDE_CODE_USE_VERTEX=1`: a session labelled `gateway` talks to Vertex, and
  keeps working while ADC is valid, so nothing reveals it.
- A server started from a gateway shell hands every pane `ANTHROPIC_BASE_URL`
  and `ANTHROPIC_AUTH_TOKEN`: an `anthropic` session sends its traffic — and its
  `sk-ant` key — to the gateway.

So the provider switch in `~/.profile`, once it knows which file it will load,
unsets all seven `CLAUDE_CODE_USE_*` provider switches Claude Code knows today
(Vertex, Bedrock, Foundry, Anthropic-on-AWS, Anthropic-on-Google-Cloud, Mantle,
gateway mode), the Anthropic and gateway credentials,
`AWS_BEARER_TOKEN_BEDROCK`, the gateway switches and the model pins, then
sources the file. Bootstrap rewrites that block on every run, so it also covers
provider files bootstrap does not own (rd-auth's subscription `anthropic.env`).
General AWS credentials (`AWS_PROFILE`, `AWS_REGION`, the key pair) and
gcloud's configuration are left alone: they are development credentials too.
On a VM with no provider files at all nothing is cleared, which keeps the
pre-multi-provider fallback intact.

The block runs in every login shell — interactive SSH logins as well as panes —
so it also drops a user's own `~/.bashrc` exports of those names there, and a
non-login shell (VS Code's terminal) gets them back. That is deliberate: a
shell cannot tell an inherited value from a chosen one, and narrowing the list
per provider would reopen one of the leaks above. The README says where such
values belong instead (an application's key in its project `.env`, Claude
preferences in `~/.claude/settings.json`).

The same frozen environment also carries `RD_PROVIDER`, and `~/.profile`
honours an inherited value — which is how `--provider` reaches a pane. A
session started without `--provider` would therefore load the frozen shell's
provider, not the VM default, while `@rd_provider` names the default. Passing
the resolved name for every new session closes that; panes created by hand in
a session `rd-start` did not create (the `main` session) still follow the
server's environment.

Pinning has one consequence for `rd-restart`: `respawn-pane` keeps the session
environment, so a restarted session reloads its own provider, never a new
default. When that provider's file is gone (the VM moved to another one), the
respawn would come back with no provider at all, so `rd-restart` refuses (exit
1, not 3 — no `--force` helps) and says to `rd-stop` and `rd-start` instead.

Not covered: the `env` block and `apiKeyHelper` of `~/.claude/settings.json`,
which Claude applies itself, after the shell. The README says to keep provider
settings out of them.

## 4. Moving a VM from Vertex to a gateway

1. In `rd.env`: `RD_PROVIDER="gateway"`, the gateway values, and
   `GCP_PROJECT_ID=""` — otherwise every re-run writes `vertex.env` back.
2. `bash ./bootstrap.sh` writes `gateway.env`, switches the default and
   refreshes the `~/.profile` block.
3. `rm ~/.config/rd/providers/vertex.env`: bootstrap never deletes a provider
   file.
4. `rd-stop` and `rd-start` each running session; a pane keeps the environment
   it started with, and `rd-start` continues the worktree's last conversation.
5. Check any `ANTHROPIC_DEFAULT_*_MODEL` pin in `~/.claude/settings.json`
   against the gateway's `/v1/models`. Vertex ids carry an `@<date>` suffix
   (`claude-haiku-4-5@20251001`) that a LiteLLM gateway rejects with "no
   healthy deployments", so every call to that model fails.
6. Decide on telemetry: Claude Code keeps metrics and `/feedback` uploads off
   by default on Vertex, Bedrock and Foundry, but a gateway session runs in
   Claude-API mode, where they are on (`DISABLE_TELEMETRY`,
   `DISABLE_FEEDBACK_COMMAND`, or `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`).

`gcloud auth` and ADC stay; they are development credentials now, not the
model provider.

## 5. Also in this change, found on the same live VM

- **bootstrap and a native Claude.** The VM's Claude had moved to the native
  installer (`~/.local/bin/claude`). `bootstrap-remote.sh` runs `bootstrap.sh`
  over plain `ssh host cmd`, a non-login shell without `~/.local/bin` on PATH,
  so `command -v claude` failed and bootstrap npm-installed a second,
  root-owned copy. Login shells keep resolving the native one, and
  `rd-update` — seeing an npm global — would update the shadowed copy, fail its
  version check and roll back. `bootstrap.sh` now prepends `~/.local/bin`
  before anything else. A VM that already has the twin keeps it (AGENTS.md says
  how to remove it).
- **rd-auth and glab's own git helper.** glab's setup writes
  `credential.<host>.helper` as an empty reset entry followed by
  `!/usr/bin/glab auth git-credential`. `rd-auth`'s plain
  `git config --global <key> <value>` exits 5 on a multi-valued key, so under
  `set -e` it stopped before the Git author was set. It now leaves any glab
  helper in place and replaces anything else with `--replace-all`.

## 6. Testing

- `tests/test-rd-auth.sh`: the key check passes the header to `curl` on stdin
  and never on its command line; a key holding `'`, `"` and `\` reaches curl's
  config byte for byte; 401 and 302 warn and the run continues to the forge;
  an unreachable gateway is reported with curl's reason and not blamed on the
  key; a missing token is called out and never counted as an accepted key; a
  URL without a scheme fails before any request; `http://` warns; a provider
  file without `ANTHROPIC_BASE_URL` fails. The git stub refuses a plain set on
  a multi-valued key, as git does, and a glab helper with a reset entry
  survives.
- `tests/test-rd-provider.sh`: a default session carries `RD_PROVIDER`.
- `tests/test-rd-restart.sh`: a session whose provider file was removed is
  refused before `--update` installs anything and before any respawn.
- `tests/smoke/smoke-provider.sh` (real tmux, real login shell, the
  `~/.profile` block evaluated out of `bootstrap.sh`): with `RD_PROVIDER=vertex`,
  a Vertex switch, an Anthropic key and a Bedrock pin in the server's global
  environment and the default moved to the gateway, a session started without
  `--provider` runs the gateway and none of those survive; with a gateway URL
  and key in the global environment, an `anthropic` session keeps its own key
  and loses both. It no longer follows `$TMUX` to the caller's server.
- `tests/smoke/smoke-bootstrap.sh`: `gateway.env` values single-quoted, a key
  with `&` and `$$` arriving byte for byte in a login shell, optional settings
  written only when set, the clearing in both directions, and a native `claude`
  in `~/.local/bin` getting no npm-global twin — with a check that run 2
  actually got past the Claude step.
- Live: a VM moved from Vertex to a LiteLLM gateway, with three running
  sessions stopped and resumed on it with their conversation ids intact.

## 7. Files touched

`bootstrap.sh`, `bin/rd-auth`, `bin/rd-start`, `bin/rd-restart`,
`rd.env.example`, `tests/test-rd-auth.sh`, `tests/test-rd-provider.sh`,
`tests/test-rd-restart.sh`, `tests/smoke/smoke-provider.sh`,
`tests/smoke/smoke-bootstrap.sh`, `README.md` (also: its Layout block now
matches AGENTS.md's), `AGENTS.md`, this document.
