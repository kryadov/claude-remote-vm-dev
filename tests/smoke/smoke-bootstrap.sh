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
check "provider files are 0600" \
  "[ \$(stat -c '%a' /root/.config/rd/providers/bedrock.env) = 600 ]"
check "default provider is RD_PROVIDER from rd.env" \
  "[ \"\$(cat /root/.config/rd/provider)\" = bedrock ]"
check "legacy 'remote-dev vertex' block removed from ~/.profile" \
  "! grep -q 'remote-dev vertex' /root/.profile"
check "exactly one 'remote-dev provider' block" \
  "[ \$(grep -c '>>> remote-dev provider >>>' /root/.profile) -eq 1 ]"
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

echo
echo "=================== bootstrap.sh run 2 (idempotency) ==================="
./bootstrap.sh >/tmp/run2.log 2>&1
echo "bootstrap exit: $?"
tail -5 /tmp/run2.log
check "still exactly one 'remote-dev provider' block after re-run" \
  "[ \$(grep -c '>>> remote-dev provider >>>' /root/.profile) -eq 1 ]"
check "no duplicated github-cli apt source" \
  "[ \$(ls /etc/apt/sources.list.d/ | grep -c github) -le 1 ]"

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
