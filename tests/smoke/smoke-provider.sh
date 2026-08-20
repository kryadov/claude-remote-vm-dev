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
chmod 600 "$HOME/.config/rd/providers"/*.env
umask 022
printf 'vertex\n' > "$HOME/.config/rd/provider"

# The ~/.profile switch, including the migration sed pair.
MARK_BEGIN="# >>> remote-dev provider >>>"
MARK_END="# <<< remote-dev provider <<<"
sed -i "/# >>> remote-dev vertex >>>/,/# <<< remote-dev vertex <<</d" "$HOME/.profile"
sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$HOME/.profile"
cat >> "$HOME/.profile" <<EOF
$MARK_BEGIN
export PATH="\$HOME/.local/bin:\$PATH"
RD_PROVIDER="\${RD_PROVIDER:-\$(cat "\$HOME/.config/rd/provider" 2>/dev/null || echo vertex)}"
if [ -r "\$HOME/.config/rd/providers/\$RD_PROVIDER.env" ]; then
  . "\$HOME/.config/rd/providers/\$RD_PROVIDER.env"
fi
export RD_PROVIDER
$MARK_END
EOF

echo
echo "== 1. ~/.profile migration =="
check "old 'remote-dev vertex' block is gone" \
  "! grep -q 'remote-dev vertex' $HOME/.profile"
check "exactly one 'remote-dev provider' block" \
  "[ \$(grep -c '>>> remote-dev provider >>>' $HOME/.profile) -eq 1 ]"
check "legacy Vertex project id no longer exported" \
  "! grep -q legacy-project $HOME/.profile"

# Re-running bootstrap's profile section must not duplicate the block.
sed -i "/# >>> remote-dev vertex >>>/,/# <<< remote-dev vertex <<</d" "$HOME/.profile"
sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$HOME/.profile"
cat >> "$HOME/.profile" <<EOF
$MARK_BEGIN
export PATH="\$HOME/.local/bin:\$PATH"
RD_PROVIDER="\${RD_PROVIDER:-\$(cat "\$HOME/.config/rd/provider" 2>/dev/null || echo vertex)}"
if [ -r "\$HOME/.config/rd/providers/\$RD_PROVIDER.env" ]; then
  . "\$HOME/.config/rd/providers/\$RD_PROVIDER.env"
fi
export RD_PROVIDER
$MARK_END
EOF
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
  "grep -P '\tdemo\tdefault\t' $SMOKE/porcelain.txt | grep -q 'vertex\$'"
check "rd-list reports bedrock for the named session" \
  "grep -P '\tdemo\tbed\t' $SMOKE/porcelain.txt | grep -q 'bedrock\$'"
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
echo "== 5. worktree isolation still holds =="
check "named session got its own worktree" \
  "[ -d $HOME/worktrees/demo/bed ]"
check "named session is on feature/bed" \
  "[ \"\$(git -C $HOME/worktrees/demo/bed branch --show-current)\" = feature/bed ]"

echo
echo "== teardown =="
tmux kill-server 2>/dev/null || true
printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
