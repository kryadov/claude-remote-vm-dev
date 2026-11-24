#!/usr/bin/env bash
# Smoke test for the provider layer, with a REAL tmux, a REAL login shell and a
# REAL git worktree — the one thing the stub-driven suites cannot prove: that
# ~/.profile plus `tmux new-session -e RD_PROVIDER=…` really delivers the right
# provider variables to a pane.
#
#   bash tests/smoke/smoke-provider.sh .
#
# Needs only bash, tmux and git. Runs entirely inside an isolated HOME
# (/tmp/crd-smoke) on a private tmux socket, so it touches nothing of yours —
# safe on a workstation, a WSL distro or the VM itself.
set -euo pipefail

REPO="$(cd "${1:?usage: smoke-provider.sh <repo-path>}" && pwd)"
SMOKE=/tmp/crd-smoke
rm -rf "$SMOKE"
mkdir -p "$SMOKE"

# On a provisioned VM this runs from a login shell that already exports the
# VM's provider. The private tmux server would inherit it, and ~/.profile
# honours an inherited RD_PROVIDER — so start from a provider-free env.
unset RD_PROVIDER CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY \
  CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD \
  CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_GATEWAY \
  ANTHROPIC_VERTEX_PROJECT_ID CLOUD_ML_REGION ANTHROPIC_API_KEY \
  CLAUDE_CODE_OAUTH_TOKEN AWS_REGION AWS_PROFILE AWS_BEARER_TOKEN_BEDROCK \
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
  ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
  ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ENABLE_TOOL_SEARCH \
  CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY CLAUDE_CODE_MAX_CONTEXT_TOKENS
# Inside tmux — and a Claude session on the VM is — $TMUX points every tmux
# command at the CALLER's server whatever TMUX_TMPDIR says, and teardown runs
# kill-server. Forget it, so the private server below is the only one touched.
unset TMUX TMUX_PANE

export HOME="$SMOKE/home"
export TMUX_TMPDIR="$SMOKE/tmux"          # private tmux server
mkdir -p "$HOME/projects" "$HOME/.config/rd/providers" "$HOME/.local/bin" "$TMUX_TMPDIR"
export PATH="$HOME/.local/bin:$PATH"

pass=0; fail=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

echo "== setup: install helpers the way bootstrap.sh does =="
install -m 0755 "$REPO"/bin/rd-* "$HOME/.local/bin/"
# rd-start launches Claude in the pane; a real one would swallow the `env`
# probes below. This one exits at once and leaves the login shell in charge.
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/claude"
chmod 0755 "$HOME/.local/bin/claude"

# A pre-multi-provider VM: the OLD Vertex block is already in ~/.profile.
cat > "$HOME/.profile" <<'EOF'
# >>> remote-dev vertex >>>
export CLAUDE_CODE_USE_VERTEX=1
export ANTHROPIC_VERTEX_PROJECT_ID=legacy-project
export CLOUD_ML_REGION=global
export PATH="$HOME/.local/bin:$PATH"
# <<< remote-dev vertex <<<
EOF

echo "== bootstrap.sh's provider sections, replayed verbatim =="
# Provider files, exactly as write_provider() emits them.
umask 077
cat > "$HOME/.config/rd/providers/vertex.env" <<'EOF'
# Written by bootstrap.sh from rd.env — edit rd.env and re-run.
export CLAUDE_CODE_USE_VERTEX=1
export ANTHROPIC_VERTEX_PROJECT_ID=smoke-vertex-project
export CLOUD_ML_REGION=global
EOF
cat > "$HOME/.config/rd/providers/bedrock.env" <<'EOF'
# Written by bootstrap.sh from rd.env — edit rd.env and re-run.
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION=eu-central-1
export AWS_PROFILE=smoke-sso
export ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-4-8
EOF
cat > "$HOME/.config/rd/providers/anthropic.env" <<'EOF'
# Written by bootstrap.sh from rd.env — edit rd.env and re-run.
export ANTHROPIC_API_KEY=sk-ant-SMOKE
EOF
cat > "$HOME/.config/rd/providers/gateway.env" <<'EOF'
# Written by bootstrap.sh from rd.env — edit rd.env and re-run.
export ANTHROPIC_BASE_URL='https://gateway.example.invalid'
export ANTHROPIC_AUTH_TOKEN='sk-gw-SMOKE'
export ENABLE_TOOL_SEARCH='true'
EOF
chmod 600 "$HOME/.config/rd/providers"/*.env
umask 022
printf 'vertex\n' > "$HOME/.config/rd/provider"

# The ~/.profile switch, including the migration sed pair — taken from
# bootstrap.sh itself (MARK_BEGIN= through its heredoc's EOF), so this test
# cannot drift from the block bootstrap really writes.
profile_switch="$(sed -n '/^MARK_BEGIN=/,/^EOF$/p' "$REPO/bootstrap.sh")"
if [ -z "$profile_switch" ]; then
  echo "could not find the ~/.profile switch in $REPO/bootstrap.sh" >&2
  exit 1
fi
eval "$profile_switch"

echo
echo "== 1. ~/.profile migration =="
check "old 'remote-dev vertex' block is gone" \
  "! grep -q 'remote-dev vertex' $HOME/.profile"
check "exactly one 'remote-dev provider' block" \
  "[ \$(grep -c '>>> remote-dev provider >>>' $HOME/.profile) -eq 1 ]"
check "legacy Vertex project id no longer exported" \
  "! grep -q legacy-project $HOME/.profile"
check "the block clears provider variables before sourcing a file" \
  "grep -q '^  unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN' $HOME/.profile"

# Re-running bootstrap's profile section must not duplicate the block.
eval "$profile_switch"
check "re-run stays idempotent (still one block)" \
  "[ \$(grep -c '>>> remote-dev provider >>>' $HOME/.profile) -eq 1 ]"
check "provider files are 0600" \
  "[ \$(stat -c '%a' $HOME/.config/rd/providers/bedrock.env) = 600 ]"

echo
echo "== 2. a real project and real sessions =="
git init -q -b main "$HOME/projects/demo"
git -C "$HOME/projects/demo" config user.name "Smoke"
git -C "$HOME/projects/demo" config user.email "smoke@example.invalid"
printf 'initial\n' > "$HOME/projects/demo/README.md"
git -C "$HOME/projects/demo" add README.md
git -C "$HOME/projects/demo" commit -q -m initial

# Dumps the pane's actual environment — this is the real question: does the
# login shell inside tmux end up with the right provider variables?
pane_env() {
  local session="$1" out="$2"
  rm -f "$out"
  tmux send-keys -t "=$session:" "env > $out" C-m
  for _ in $(seq 1 50); do [ -s "$out" ] && return 0; sleep 0.2; done
  return 1
}

rd-start demo >/dev/null
pane_env claude-demo "$SMOKE/env-default.txt" || echo "  (pane never answered)"
check "default session: RD_PROVIDER=vertex" \
  "grep -qx 'RD_PROVIDER=vertex' $SMOKE/env-default.txt"
check "default session: CLAUDE_CODE_USE_VERTEX=1" \
  "grep -qx 'CLAUDE_CODE_USE_VERTEX=1' $SMOKE/env-default.txt"
check "default session: Vertex project id from the provider file" \
  "grep -qx 'ANTHROPIC_VERTEX_PROJECT_ID=smoke-vertex-project' $SMOKE/env-default.txt"
check "default session: no Bedrock variables leaked in" \
  "! grep -q 'CLAUDE_CODE_USE_BEDROCK' $SMOKE/env-default.txt"

rd-start demo --session bed --provider bedrock >/dev/null
pane_env claude-demo--bed "$SMOKE/env-bedrock.txt" || echo "  (pane never answered)"
check "override: RD_PROVIDER=bedrock reached the pane" \
  "grep -qx 'RD_PROVIDER=bedrock' $SMOKE/env-bedrock.txt"
check "override: CLAUDE_CODE_USE_BEDROCK=1" \
  "grep -qx 'CLAUDE_CODE_USE_BEDROCK=1' $SMOKE/env-bedrock.txt"
check "override: AWS_REGION from the provider file" \
  "grep -qx 'AWS_REGION=eu-central-1' $SMOKE/env-bedrock.txt"
check "override: model pin present" \
  "grep -q 'ANTHROPIC_DEFAULT_OPUS_MODEL=' $SMOKE/env-bedrock.txt"
check "override: Vertex variables NOT set in this pane" \
  "! grep -q 'CLAUDE_CODE_USE_VERTEX' $SMOKE/env-bedrock.txt"

echo
echo "== 3. no secret on a command line or in the session environment =="
check "tmux session env carries only RD_PROVIDER" \
  "[ \"\$(tmux show-environment -t '=claude-demo--bed' 2>/dev/null | grep -c '^ANTHROPIC_API_KEY\\|^AWS_SECRET')\" = 0 ]"
check "the API key never reached the bedrock pane" \
  "! grep -q 'sk-ant-SMOKE' $SMOKE/env-bedrock.txt"

echo
echo "== 4. rd-list / rd-start guardrails against a live server =="
rd-list --porcelain > "$SMOKE/porcelain.txt"
check "rd-list reports vertex for the default session" \
  "awk -F'\t' '\$2 == \"demo\" && \$3 == \"default\" && \$7 == \"vertex\"' $SMOKE/porcelain.txt | grep -q ."
check "rd-list reports bedrock for the named session" \
  "awk -F'\t' '\$2 == \"demo\" && \$3 == \"bed\" && \$7 == \"bedrock\"' $SMOKE/porcelain.txt | grep -q ."
# Captured rather than piped into head: `set -o pipefail` here would otherwise
# report rd-list's SIGPIPE death as a failure of the column itself.
rd-list > "$SMOKE/human.txt"
check "rd-list human table has a PROVIDER column" \
  "head -1 $SMOKE/human.txt | grep -q PROVIDER"
check "rd-list human table shows the provider value" \
  "grep -q ' vertex ' $SMOKE/human.txt"
check "changing a running session's provider is rejected" \
  "! rd-start demo --session bed --provider anthropic"
check "unknown provider is rejected" \
  "! rd-start demo --session other --provider nope"

echo
echo "== 5. rd-restart keeps the pane's provider =="
# respawn-pane must hand the session environment (RD_PROVIDER) to the new
# login shell, or a restarted --provider session silently falls back to the
# VM default. --force: no real Claude ran, so no hook ever reported a state.
rd-restart demo --session bed --force >/dev/null 2>&1 || true
pane_env claude-demo--bed "$SMOKE/env-restarted.txt" || echo "  (pane never answered)"
check "after rd-restart: RD_PROVIDER=bedrock" \
  "grep -qx 'RD_PROVIDER=bedrock' $SMOKE/env-restarted.txt"
check "after rd-restart: CLAUDE_CODE_USE_BEDROCK=1" \
  "grep -qx 'CLAUDE_CODE_USE_BEDROCK=1' $SMOKE/env-restarted.txt"
check "after rd-restart: pane is back in the worktree" \
  "grep -qx 'PWD=$HOME/worktrees/demo/bed' $SMOKE/env-restarted.txt"

echo
echo "== 6. inherited provider state cannot pick or bend a session's provider =="
# A tmux server started by hand from a login shell keeps that shell's provider
# in its global environment: RD_PROVIDER plus whatever its file exported. Fake
# one started from a Vertex shell, then move the VM default to the gateway the
# way the README's "Removing a provider" does.
tmux set-environment -g RD_PROVIDER vertex
tmux set-environment -g CLAUDE_CODE_USE_VERTEX 1
tmux set-environment -g ANTHROPIC_VERTEX_PROJECT_ID legacy-project
tmux set-environment -g ANTHROPIC_API_KEY sk-ant-INHERITED
tmux set-environment -g ANTHROPIC_DEFAULT_OPUS_MODEL us.anthropic.claude-opus-4-8
tmux set-environment -g CLAUDE_CODE_USE_MANTLE 1
printf 'gateway\n' > "$HOME/.config/rd/provider"
rd-start demo --session gw >/dev/null
pane_env claude-demo--gw "$SMOKE/env-gateway.txt" || echo "  (pane never answered)"
check "new default: the session carries RD_PROVIDER=gateway" \
  "tmux show-environment -t '=claude-demo--gw' RD_PROVIDER | grep -qx 'RD_PROVIDER=gateway'"
check "new default: the pane runs the gateway, not the frozen vertex" \
  "grep -qx 'RD_PROVIDER=gateway' $SMOKE/env-gateway.txt"
check "gateway: ANTHROPIC_BASE_URL from the provider file" \
  "grep -qx 'ANTHROPIC_BASE_URL=https://gateway.example.invalid' $SMOKE/env-gateway.txt"
check "gateway: optional switch from the provider file" \
  "grep -qx 'ENABLE_TOOL_SEARCH=true' $SMOKE/env-gateway.txt"
check "gateway: inherited CLAUDE_CODE_USE_VERTEX is gone" \
  "! grep -q '^CLAUDE_CODE_USE_VERTEX=' $SMOKE/env-gateway.txt"
check "gateway: inherited Anthropic key is gone" \
  "! grep -q '^ANTHROPIC_API_KEY=' $SMOKE/env-gateway.txt"
check "gateway: inherited Bedrock model pin is gone" \
  "! grep -q '^ANTHROPIC_DEFAULT_OPUS_MODEL=' $SMOKE/env-gateway.txt"
check "gateway: an inherited switch for a newer provider is gone too" \
  "! grep -q '^CLAUDE_CODE_USE_MANTLE=' $SMOKE/env-gateway.txt"
check "gateway: the key stays out of the tmux session environment" \
  "! tmux show-environment -t '=claude-demo--gw' 2>/dev/null | grep -q 'sk-gw-SMOKE'"

# The other direction: a server started from a gateway shell must not send an
# 'anthropic' session — and its key — to the gateway.
tmux set-environment -g ANTHROPIC_BASE_URL https://leak.invalid
tmux set-environment -g ANTHROPIC_AUTH_TOKEN sk-gw-LEAK
rd-start demo --session api --provider anthropic >/dev/null
pane_env claude-demo--api "$SMOKE/env-anthropic.txt" || echo "  (pane never answered)"
check "anthropic: its own key from the provider file" \
  "grep -qx 'ANTHROPIC_API_KEY=sk-ant-SMOKE' $SMOKE/env-anthropic.txt"
check "anthropic: inherited gateway base URL is gone" \
  "! grep -q '^ANTHROPIC_BASE_URL=' $SMOKE/env-anthropic.txt"
check "anthropic: inherited gateway key is gone" \
  "! grep -q '^ANTHROPIC_AUTH_TOKEN=' $SMOKE/env-anthropic.txt"
for var in RD_PROVIDER CLAUDE_CODE_USE_VERTEX ANTHROPIC_VERTEX_PROJECT_ID ANTHROPIC_API_KEY \
           ANTHROPIC_DEFAULT_OPUS_MODEL CLAUDE_CODE_USE_MANTLE ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN; do
  tmux set-environment -g -u "$var"
done
printf 'vertex\n' > "$HOME/.config/rd/provider"

echo
echo "== 7. worktree isolation still holds =="
check "named session got its own worktree" \
  "[ -d $HOME/worktrees/demo/bed ]"
check "named session is on feature/bed" \
  "[ \"\$(git -C $HOME/worktrees/demo/bed branch --show-current)\" = feature/bed ]"

echo
echo "== teardown =="
tmux kill-server 2>/dev/null || true
printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
