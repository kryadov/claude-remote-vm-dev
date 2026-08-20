#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/gcloud-log"
exit 0
EOF

cat > "$TEST_ROOT/bin/glab" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/glab-log"
if [[ "$1 $2" == "auth status" ]]; then
  echo "gitlab.example.com"
  exit 0
fi
exit 1
EOF

cat > "$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/gh-log"
# Not logged in yet, so rd-auth has to run the login flow.
[[ "$1 $2" == "auth status" ]] && exit 1
exit 0
EOF

cat > "$TEST_ROOT/bin/aws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/aws-log"
# No cached SSO session, so rd-auth has to run `aws sso login`.
[[ "$1 $2" == "sso login" ]] && exit 0
exit 1
EOF

cat > "$TEST_ROOT/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/claude-log"
[[ "$1" == "setup-token" ]] || exit 1
echo "sk-ant-oat01-EXAMPLE"
EOF

# Stores each `git config --global` key in its own file. Keys are flattened to
# a safe filename so scoped keys (credential.https://host.helper) work too.
cat > "$TEST_ROOT/bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/git-log"
key_file() {
  printf '%s/.gitconfig-%s' "$HOME" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"
}
if [[ "$1 $2 $3" == "config --global --get" ]]; then
  cat "$(key_file "$4")" 2>/dev/null
  exit $?
fi
if [[ "$1 $2 $3" == "config --global --unset" ]]; then
  rm -f "$(key_file "$4")"
  exit 0
fi
if [[ "$1 $2" == "config --global" ]]; then
  printf '%s' "$3" > "$(key_file "$3").key"
  printf '%s' "$4" > "$(key_file "$3")"
  exit 0
fi
exit 1
EOF

chmod +x "$TEST_ROOT/bin"/*

# A HOME with a valid rd.env. $1 names the case, $2 the default provider,
# and any further arguments replace the rd.env body.
auth_home() {
  local home="$TEST_ROOT/$1/home" provider="$2"
  shift 2
  mkdir -p "$home/remote-dev" "$home/.config/rd/providers"
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@" > "$home/remote-dev/rd.env"
  else
    cat > "$home/remote-dev/rd.env" <<'ENV'
REPO_URL="https://gitlab.example.com/example/remote-dev.git"
GIT_USER_NAME="Example Developer"
GIT_USER_EMAIL="developer@example.com"
ENV
  fi
  printf '%s\n' "$provider" > "$home/.config/rd/provider"
  printf 'export CLAUDE_CODE_USE_VERTEX=1\n' > "$home/.config/rd/providers/vertex.env"
  printf '%s' "$home"
}

run_auth() {
  local home="$1"
  shift
  HOME="$home" PATH="$TEST_ROOT/bin:$PATH" "$ROOT_DIR/bin/rd-auth" "$@"
}

git_value() {
  local home="$1" key="$2"
  cat "$home/.gitconfig-$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '-')" 2>/dev/null || true
}

# --- git author ---------------------------------------------------------------

test_configures_git_author_from_rd_env() {
  local home
  home="$(auth_home configured vertex)"

  run_auth "$home" >/dev/null

  [[ "$(git_value "$home" user.name)" == "Example Developer" ]]
  [[ "$(git_value "$home" user.email)" == "developer@example.com" ]]
}

test_rejects_missing_git_author() {
  local home output
  home="$(auth_home missing vertex \
    'REPO_URL="https://gitlab.example.com/example/remote-dev.git"')"

  if output="$(run_auth "$home" 2>&1)"; then
    echo "rd-auth unexpectedly accepted missing Git author settings" >&2
    return 1
  fi
  [[ "$output" == *"GIT_USER_NAME"* ]]
  [[ "$output" == *"GIT_USER_EMAIL"* ]]
}

# --- model providers ----------------------------------------------------------

test_vertex_runs_adc_login() {
  local home
  home="$(auth_home vertex vertex)"

  run_auth "$home" >/dev/null

  grep -q "application-default" "$home/gcloud-log"
}

test_bedrock_sso_login() {
  local home
  home="$(auth_home bedrock bedrock)"
  cat > "$home/.config/rd/providers/bedrock.env" <<'EOF'
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION=eu-central-1
export AWS_PROFILE=dev-sso
EOF

  run_auth "$home" >/dev/null

  grep -q -- "sso login --profile dev-sso" "$home/aws-log"
  # Vertex ADC must not run when Bedrock is the provider.
  [[ ! -f "$home/gcloud-log" ]]
}

test_bedrock_static_credential_needs_no_login() {
  local home
  home="$(auth_home bedrock-static bedrock)"
  cat > "$home/.config/rd/providers/bedrock.env" <<'EOF'
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION=eu-central-1
export AWS_BEARER_TOKEN_BEDROCK=example-key
EOF

  run_auth "$home" >/dev/null

  [[ ! -f "$home/aws-log" ]]
}

test_bedrock_without_any_credential_fails() {
  local home output
  home="$(auth_home bedrock-empty bedrock)"
  cat > "$home/.config/rd/providers/bedrock.env" <<'EOF'
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION=eu-central-1
EOF

  if output="$(run_auth "$home" 2>&1)"; then
    echo "rd-auth accepted a Bedrock provider with no credential" >&2
    return 1
  fi
  [[ "$output" == *"AWS_PROFILE"* ]]
}

test_anthropic_subscription_writes_oauth_token() {
  local home mode
  home="$(auth_home anthropic anthropic)"
  printf '# anthropic\n' > "$home/.config/rd/providers/anthropic.env"

  run_auth "$home" >/dev/null

  grep -q "setup-token" "$home/claude-log"
  grep -q 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-EXAMPLE' \
    "$home/.config/rd/providers/anthropic.env"
  mode="$(stat -c '%a' "$home/.config/rd/providers/anthropic.env")"
  [[ "$mode" == "600" ]]
}

test_anthropic_api_key_needs_no_login() {
  local home
  home="$(auth_home apikey anthropic)"
  printf 'export ANTHROPIC_API_KEY=sk-ant-EXAMPLE\n' \
    > "$home/.config/rd/providers/anthropic.env"

  run_auth "$home" >/dev/null

  [[ ! -f "$home/claude-log" ]]
}

test_provider_flag_overrides_the_default() {
  local home
  home="$(auth_home flag vertex)"
  cat > "$home/.config/rd/providers/bedrock.env" <<'EOF'
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_PROFILE=dev-sso
EOF

  run_auth "$home" --provider bedrock >/dev/null

  grep -q -- "sso login --profile dev-sso" "$home/aws-log"
  [[ ! -f "$home/gcloud-log" ]]
}

# --- forges -------------------------------------------------------------------

test_gitlab_credential_helper_is_host_scoped() {
  local home
  home="$(auth_home scoped vertex)"

  run_auth "$home" >/dev/null

  [[ "$(git_value "$home" 'credential.https://gitlab.example.com.helper')" \
     == '!glab auth git-credential' ]]
  # A global helper would answer for GitHub hosts too.
  [[ -z "$(git_value "$home" credential.helper)" ]]
}

test_github_remote_uses_gh() {
  local home
  home="$(auth_home github vertex \
    'REPO_URL="https://github.example.com/example/remote-dev.git"' \
    'FORGE="github"' \
    'GIT_USER_NAME="Example Developer"' \
    'GIT_USER_EMAIL="developer@example.com"')"

  run_auth "$home" >/dev/null

  grep -q -- "auth login --hostname github.example.com" "$home/gh-log"
  grep -q -- "auth setup-git --hostname github.example.com" "$home/gh-log"
  [[ ! -f "$home/glab-log" ]]
}

test_github_dot_com_is_detected_without_forge_key() {
  local home
  home="$(auth_home ghdotcom vertex \
    'REPO_URL="https://github.com/example/remote-dev.git"' \
    'GIT_USER_NAME="Example Developer"' \
    'GIT_USER_EMAIL="developer@example.com"')"

  run_auth "$home" >/dev/null

  grep -q -- "auth login --hostname github.com" "$home/gh-log"
}

test_forge_flag_overrides_detection() {
  local home
  home="$(auth_home forgeflag vertex \
    'REPO_URL="https://scm.example.com/example/remote-dev.git"' \
    'GIT_USER_NAME="Example Developer"' \
    'GIT_USER_EMAIL="developer@example.com"')"

  run_auth "$home" --forge github >/dev/null

  grep -q -- "auth login --hostname scm.example.com" "$home/gh-log"
  [[ ! -f "$home/glab-log" ]]
}

# A host named after neither forge, with nobody to ask, must fail loudly
# rather than guess or hang on a prompt.
test_ambiguous_host_without_a_tty_fails() {
  local home output
  home="$(auth_home ambiguous vertex \
    'REPO_URL="https://scm.example.com/example/remote-dev.git"' \
    'GIT_USER_NAME="Example Developer"' \
    'GIT_USER_EMAIL="developer@example.com"')"

  if output="$(run_auth "$home" </dev/null 2>&1)"; then
    echo "rd-auth guessed the forge for an ambiguous host" >&2
    return 1
  fi
  [[ "$output" == *"--forge"* ]]
}

test_migrates_legacy_global_credential_helper() {
  local home
  home="$(auth_home legacy vertex)"
  printf '%s' '!glab auth git-credential' \
    > "$home/.gitconfig-credential-helper"

  run_auth "$home" >/dev/null

  [[ -z "$(git_value "$home" credential.helper)" ]]
  [[ "$(git_value "$home" 'credential.https://gitlab.example.com.helper')" \
     == '!glab auth git-credential' ]]
}

test_configures_git_author_from_rd_env
test_rejects_missing_git_author
test_vertex_runs_adc_login
test_bedrock_sso_login
test_bedrock_static_credential_needs_no_login
test_bedrock_without_any_credential_fails
test_anthropic_subscription_writes_oauth_token
test_anthropic_api_key_needs_no_login
test_provider_flag_overrides_the_default
test_gitlab_credential_helper_is_host_scoped
test_github_remote_uses_gh
test_github_dot_com_is_detected_without_forge_key
test_forge_flag_overrides_detection
test_ambiguous_host_without_a_tty_fails
test_migrates_legacy_global_credential_helper
echo "rd-auth tests passed"
