#!/usr/bin/env bash
# Runs the real bootstrap.sh in a throwaway Ubuntu container and inspects what
# it produced: the installs, the provider files, the ~/.profile migration off
# the old 'remote-dev vertex' block, and idempotency on a second run.
#
# Everything that needs a running init (systemd user service, loginctl linger)
# cannot work in a container, so the run stops at that section — expected.
#
# From the repo root:
#   docker run --rm -v "$(pwd)":/src -w /work ubuntu:24.04 bash -c \
#     'cp -r /src/. /work/ && bash /work/tests/smoke/smoke-bootstrap.sh'
#
# On Windows/Git Bash use "$(pwd -W)" for the mount and prefix the command with
# MSYS_NO_PATHCONV=1.
#
# DESTRUCTIVE: overwrites ~/.profile and installs packages. Container only —
# never run it on a machine you care about.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

if [ ! -f /.dockerenv ] && [ "${ALLOW_UNSAFE_SMOKE:-}" != 1 ]; then
  echo "refusing to run outside a container (set ALLOW_UNSAFE_SMOKE=1 to override)" >&2
  exit 2
fi

# bootstrap.sh calls sudo; as root in a container a passthrough shim is both
# simpler and closer to the VM's passwordless-sudo assumption than installing
# the real thing.
cat > /usr/local/bin/sudo <<'EOF'
#!/bin/sh
exec "$@"
EOF
chmod +x /usr/local/bin/sudo

# A pre-multi-provider VM, so the migration path is exercised for real.
cat > /root/.profile <<'EOF'
# >>> remote-dev vertex >>>
export CLAUDE_CODE_USE_VERTEX=1
export ANTHROPIC_VERTEX_PROJECT_ID=legacy-project
export CLOUD_ML_REGION=global
export PATH="$HOME/.local/bin:$PATH"
# <<< remote-dev vertex <<<
EOF

cat > rd.env <<'EOF'
VM_IP="10.0.0.10"
VM_USER="ubuntu"
SSH_KEY="$HOME/.ssh/dev-vm.pem"
REPO_URL="https://gitlab.example.com/example/claude-remote-dev.git"
GIT_CLONE_TOKEN=""
FORGE=""
RD_PROVIDER="bedrock"
GCP_PROJECT_ID="smoke-vertex-project"
CLOUD_ML_REGION="global"
AWS_REGION="eu-central-1"
AWS_PROFILE="smoke-sso"
ANTHROPIC_DEFAULT_OPUS_MODEL="us.anthropic.claude-opus-4-8"
ANTHROPIC_API_KEY="sk-ant-SMOKE"
ANTHROPIC_BASE_URL="https://gateway.example.invalid"
ANTHROPIC_AUTH_TOKEN='sk-gw-SMOKE&$$x'
ENABLE_TOOL_SEARCH="true"
GIT_USER_NAME="Smoke Tester"
GIT_USER_EMAIL="smoke@example.invalid"
EOF

echo "=================== bootstrap.sh run 1 ==================="
./bootstrap.sh 2>&1 | tail -25
echo "bootstrap exit: ${PIPESTATUS[0]}"

pass=0; fail=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

echo
echo "=================== what it produced ==================="
echo "--- installed CLIs ---"
for c in gh glab aws node claude; do
  printf '  %-7s %s\n' "$c" "$(command -v $c || echo MISSING)"
done

echo
echo "--- provider config ---"
ls -l /root/.config/rd/providers/ 2>/dev/null || echo "  (no provider dir)"
echo "  default: $(cat /root/.config/rd/provider 2>/dev/null || echo none)"

echo
check "vertex.env written from GCP_PROJECT_ID" \
  "grep -q 'ANTHROPIC_VERTEX_PROJECT_ID=smoke-vertex-project' /root/.config/rd/providers/vertex.env"
check "bedrock.env written from AWS_REGION" \
  "grep -q 'AWS_REGION=eu-central-1' /root/.config/rd/providers/bedrock.env"
check "bedrock.env carries the SSO profile" \
  "grep -q 'AWS_PROFILE=smoke-sso' /root/.config/rd/providers/bedrock.env"
check "bedrock.env carries the model pin" \
  "grep -q 'ANTHROPIC_DEFAULT_OPUS_MODEL=' /root/.config/rd/providers/bedrock.env"
check "anthropic.env written from ANTHROPIC_API_KEY" \
  "grep -q 'ANTHROPIC_API_KEY=sk-ant-SMOKE' /root/.config/rd/providers/anthropic.env"
# The key holds characters the shell would act on ($$ is its PID, & forks), so
# the expected lines live in variables and the checks use single quotes.
GW_TOKEN='sk-gw-SMOKE&$$x'
# shellcheck disable=SC2034  # read inside check's eval
GW_TOKEN_LINE="export ANTHROPIC_AUTH_TOKEN='$GW_TOKEN'"
check "gateway.env written from ANTHROPIC_BASE_URL, single-quoted" \
  "grep -qx \"export ANTHROPIC_BASE_URL='https://gateway.example.invalid'\" /root/.config/rd/providers/gateway.env"
check "gateway.env carries the gateway key, single-quoted" \
  'grep -qxF -- "$GW_TOKEN_LINE" /root/.config/rd/providers/gateway.env'
check "gateway.env writes an optional switch that is set" \
  "grep -qx \"export ENABLE_TOOL_SEARCH='true'\" /root/.config/rd/providers/gateway.env"
check "gateway.env leaves out optional switches that are not" \
  "! grep -q 'CLAUDE_CODE_MAX_CONTEXT_TOKENS' /root/.config/rd/providers/gateway.env"
check "gateway.env holds nothing but its exports (clearing is ~/.profile's job)" \
  "! grep -v -e '^#' -e '^export ' /root/.config/rd/providers/gateway.env | grep -q ."
check "gateway.env is 0600" \
  "[ \$(stat -c '%a' /root/.config/rd/providers/gateway.env) = 600 ]"
check "provider files are 0600" \
  "[ \$(stat -c '%a' /root/.config/rd/providers/bedrock.env) = 600 ]"
check "default provider is RD_PROVIDER from rd.env" \
  "[ \"\$(cat /root/.config/rd/provider)\" = bedrock ]"
check "legacy 'remote-dev vertex' block removed from ~/.profile" \
  "! grep -q 'remote-dev vertex' /root/.profile"
check "exactly one 'remote-dev provider' block" \
  "[ \$(grep -c '>>> remote-dev provider >>>' /root/.profile) -eq 1 ]"
check "the block clears provider variables before sourcing a file" \
  "grep -q '^  unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN' /root/.profile"
check "rd-* helpers installed to ~/.local/bin" \
  "[ -x /root/.local/bin/rd-start ] && [ -x /root/.local/bin/rd-auth ]"
check "gh installed" "command -v gh"
check "glab installed" "command -v glab"
check "aws installed" "command -v aws"

echo
echo "--- a real login shell picks up the default provider ---"
env -i HOME=/root bash -lc 'env' > /tmp/login-env.txt 2>/dev/null
check "login shell exports RD_PROVIDER=bedrock" \
  "grep -qx 'RD_PROVIDER=bedrock' /tmp/login-env.txt"
check "login shell exports CLAUDE_CODE_USE_BEDROCK=1" \
  "grep -qx 'CLAUDE_CODE_USE_BEDROCK=1' /tmp/login-env.txt"
check "login shell does NOT export Vertex vars" \
  "! grep -q 'CLAUDE_CODE_USE_VERTEX' /tmp/login-env.txt"
env -i HOME=/root RD_PROVIDER=anthropic bash -lc 'env' > /tmp/login-env2.txt 2>/dev/null
check "a preset RD_PROVIDER wins (the rd-start override path)" \
  "grep -qx 'ANTHROPIC_API_KEY=sk-ant-SMOKE' /tmp/login-env2.txt"
# A pane can inherit another provider's state (tmux server env, ~/.bashrc):
# a Vertex switch, an Anthropic key, a Bedrock model pin. None may survive
# into a gateway session...
env -i HOME=/root RD_PROVIDER=gateway CLAUDE_CODE_USE_VERTEX=1 ANTHROPIC_API_KEY=sk-ant-INHERITED \
  ANTHROPIC_DEFAULT_OPUS_MODEL=us.anthropic.claude-opus-4-8 \
  bash -lc 'env' > /tmp/login-env3.txt 2>/dev/null
check "gateway login shell exports the gateway's base URL" \
  "grep -qx 'ANTHROPIC_BASE_URL=https://gateway.example.invalid' /tmp/login-env3.txt"
check "gateway login shell gets the key byte for byte" \
  'grep -qxF -- "ANTHROPIC_AUTH_TOKEN=$GW_TOKEN" /tmp/login-env3.txt'
check "gateway login shell drops an inherited Vertex switch" \
  "! grep -q '^CLAUDE_CODE_USE_VERTEX=' /tmp/login-env3.txt"
check "gateway login shell drops an inherited Anthropic key" \
  "! grep -q '^ANTHROPIC_API_KEY=' /tmp/login-env3.txt"
check "gateway login shell drops an inherited Bedrock model pin" \
  "! grep -q '^ANTHROPIC_DEFAULT_OPUS_MODEL=' /tmp/login-env3.txt"
# ...and a gateway's base URL and key may not bend an 'anthropic' session.
env -i HOME=/root RD_PROVIDER=anthropic ANTHROPIC_BASE_URL=https://leak.invalid \
  ANTHROPIC_AUTH_TOKEN=sk-gw-LEAK bash -lc 'env' > /tmp/login-env4.txt 2>/dev/null
check "anthropic login shell keeps its own key" \
  "grep -qx 'ANTHROPIC_API_KEY=sk-ant-SMOKE' /tmp/login-env4.txt"
check "anthropic login shell drops an inherited gateway URL and key" \
  "! grep -q -e '^ANTHROPIC_BASE_URL=' -e '^ANTHROPIC_AUTH_TOKEN=' /tmp/login-env4.txt"

echo
echo "--- a native claude in ~/.local/bin, unseen by this shell's PATH ---"
# bootstrap-remote.sh runs bootstrap over plain `ssh host cmd`, whose PATH
# lacks ~/.local/bin — like this script's. A native install lives there and
# must not get an npm-global twin on the next run.
npm uninstall -g @anthropic-ai/claude-code >/dev/null 2>&1
mkdir -p /root/.local/bin
cat > /root/.local/bin/claude <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "2.1.999 (Claude Code)" ;;
  plugin) echo "atlassian@claude-plugins-official" ;;
esac
exit 0
EOF
chmod +x /root/.local/bin/claude

echo
echo "=================== bootstrap.sh run 2 (idempotency) ==================="
./bootstrap.sh >/tmp/run2.log 2>&1
echo "bootstrap exit: $?"
tail -5 /tmp/run2.log
# The two absences below would also hold if run 2 died before the Claude step.
check "run 2 got past the Claude step" \
  "grep -q 'Provider config in ~/.config/rd' /tmp/run2.log"
check "native claude in ~/.local/bin: run 2 skipped the npm install" \
  "! grep -q 'Claude Code CLI (npm global)' /tmp/run2.log"
check "native claude in ~/.local/bin: no npm-global copy appeared" \
  "! npm ls -g --depth=0 @anthropic-ai/claude-code"
check "still exactly one 'remote-dev provider' block after re-run" \
  "[ \$(grep -c '>>> remote-dev provider >>>' /root/.profile) -eq 1 ]"
check "no duplicated github-cli apt source" \
  "[ \$(ls /etc/apt/sources.list.d/ | grep -c github) -le 1 ]"

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
