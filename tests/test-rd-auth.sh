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
  # Mirrors the real CLI: a scoped check succeeds, while the unscoped one
  # still prints every host but exits non-zero when ANY configured instance
  # fails to authenticate — a stale gitlab.com entry is enough.
  if [[ "$*" == *--hostname* ]]; then
    echo "gitlab.example.com"
    exit 0
  fi
  echo "gitlab.example.com"
  echo "gitlab.com: API call failed: 401 Unauthorized"
  exit 1
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
echo "Visit https://claude.example/oauth to authorize"
echo "sk-ant-oat01-EXAMPLE"
EOF

# Records the command line and the config read from stdin (-K -) apart, since
# a gateway key must reach curl through stdin only. Prints the HTTP status
# rd-auth asks for with -w '%{http_code}': $HOME/curl-status, default 200.
cat > "$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/curl-argv"
cat >> "$HOME/curl-stdin"
status="$(cat "$HOME/curl-status" 2>/dev/null || echo 200)"
printf '%s' "$status"
# Like real curl when nothing answered: -w still prints 000, -S explains why.
if [[ "$status" == 000 ]]; then
  echo "curl: (6) Could not resolve host: gateway.example.com" >&2
  exit 6
fi
EOF

# Stores each `git config --global` key in its own file. Keys are flattened to
# a safe filename so scoped keys (credential.https://host.helper) work too. A
# file may hold several values, one per line, like a multi-valued key — and,
# as in real git, a plain set cannot overwrite those.
cat > "$TEST_ROOT/bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/git-log"
key_file() {
  printf '%s/.gitconfig-%s' "$HOME" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"
}
if [[ "$1 $2 $3" == "config --global --get" ]]; then
  [[ -f "$(key_file "$4")" ]] || exit 1
  tail -n 1 "$(key_file "$4")"
  exit 0
fi
if [[ "$1 $2 $3" == "config --global --get-all" ]]; then
  [[ -f "$(key_file "$4")" ]] || exit 1
  cat "$(key_file "$4")"
  exit 0
fi
if [[ "$1 $2 $3" == "config --global --unset" ]]; then
  rm -f "$(key_file "$4")"
  exit 0
fi
if [[ "$1 $2 $3" == "config --global --replace-all" ]]; then
  printf '%s' "$4" > "$(key_file "$4").key"
  printf '%s' "$5" > "$(key_file "$4")"
  exit 0
fi
if [[ "$1 $2" == "config --global" ]]; then
  if [[ -f "$(key_file "$3")" && "$(grep -c '' "$(key_file "$3")")" -gt 1 ]]; then
    echo "error: cannot overwrite multiple values with a single value" >&2
    exit 5
  fi
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

  local output
  # The token is pasted back after setup-token, which must own the terminal.
  output="$(run_auth "$home" <<< "sk-ant-oat01-EXAMPLE")"

  grep -q "setup-token" "$home/claude-log"
  # setup-token's own output (URL, code prompt) must reach the user, not a pipe.
  [[ "$output" == *"Visit https://claude.example/oauth"* ]] || {
    echo "setup-token output was swallowed: $output" >&2
    return 1
  }
  grep -q 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-EXAMPLE' \
    "$home/.config/rd/providers/anthropic.env"
  mode="$(stat -c '%a' "$home/.config/rd/providers/anthropic.env")"
  [[ "$mode" == "600" ]]
}

# The prompt is hidden, so users paste again when nothing seems to happen.
test_anthropic_subscription_keeps_one_token_from_a_repeated_paste() {
  local home output
  home="$(auth_home repaste anthropic)"
  printf '# anthropic\n' > "$home/.config/rd/providers/anthropic.env"

  output="$(run_auth "$home" <<< "sk-ant-oat01-EXAMPLEsk-ant-oat01-EXAMPLEsk-ant-oat01-EXA")"
  grep -qx 'export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-EXAMPLE' \
    "$home/.config/rd/providers/anthropic.env"
  # setup-token prints the token itself; rd-auth's confirmation must not.
  [[ "$(grep 'received' <<< "$output")" == "   received sk-ant-oat01-E… (20 chars)" ]] || {
    echo "unexpected confirmation: $(grep 'received' <<< "$output")" >&2
    return 1
  }
}

# First-run onboarding would otherwise stop every new session on a login
# picker that ignores the provider's credentials.
test_onboarding_is_marked_done() {
  local home
  command -v jq >/dev/null 2>&1 || { echo "  (skipped: no jq)"; return 0; }
  home="$(auth_home onboarding anthropic)"
  printf 'export ANTHROPIC_API_KEY=sk-ant-EXAMPLE\n' \
    > "$home/.config/rd/providers/anthropic.env"
  printf '{"userID": "x"}\n' > "$home/.claude.json"

  run_auth "$home" >/dev/null

  [[ "$(jq -r .hasCompletedOnboarding "$home/.claude.json")" == "true" ]]
  [[ "$(jq -r .userID "$home/.claude.json")" == "x" ]]
}

test_anthropic_subscription_rejects_a_bad_paste() {
  local home
  home="$(auth_home badpaste anthropic)"
  printf '# anthropic\n' > "$home/.config/rd/providers/anthropic.env"

  if run_auth "$home" <<< "not-a-token" >/dev/null 2>&1; then
    echo "rd-auth stored something that is not a Claude token" >&2
    return 1
  fi
  ! grep -q CLAUDE_CODE_OAUTH_TOKEN "$home/.config/rd/providers/anthropic.env"
}

test_anthropic_api_key_needs_no_login() {
  local home
  home="$(auth_home apikey anthropic)"
  printf 'export ANTHROPIC_API_KEY=sk-ant-EXAMPLE\n' \
    > "$home/.config/rd/providers/anthropic.env"

  run_auth "$home" >/dev/null

  [[ ! -f "$home/claude-log" ]]
}

# The file as bootstrap.sh writes it (values single-quoted). $2 replaces the
# URL; the default's trailing slash is deliberate — rd-auth must not probe
# "//v1/models".
gateway_file() {
  cat > "$1/.config/rd/providers/gateway.env" <<EOF
# Written by bootstrap.sh from rd.env — edit rd.env and re-run.
export ANTHROPIC_BASE_URL='${2:-https://gateway.example.com/}'
export ANTHROPIC_AUTH_TOKEN='sk-gw-EXAMPLE'
EOF
}

test_gateway_checks_the_key_without_exposing_it() {
  local home output
  home="$(auth_home gateway gateway)"
  gateway_file "$home"

  output="$(run_auth "$home" 2>&1)"

  [[ "$output" == *"accepted the key"* ]]
  grep -qx -- "-sS -o /dev/null -w %{http_code} --max-time 20 -K - https://gateway.example.com/v1/models" \
    "$home/curl-argv"
  # The key travels in curl's config on stdin, never as an argument (ps shows those).
  if grep -q "sk-gw-EXAMPLE" "$home/curl-argv"; then
    echo "the gateway key reached curl's command line" >&2
    return 1
  fi
  grep -qx 'header = "Authorization: Bearer sk-gw-EXAMPLE"' "$home/curl-stdin"
  # No other provider's login runs, and the forge and Git author steps still do.
  [[ ! -f "$home/gcloud-log" && ! -f "$home/aws-log" && ! -f "$home/claude-log" ]]
  [[ "$(git_value "$home" user.name)" == "Example Developer" ]]
}

# A refused key is worth a warning, not an abort: the forge login after it is
# independent of the model provider.
test_gateway_refusing_the_key_warns_but_continues() {
  local home output
  home="$(auth_home gateway-refused gateway)"
  gateway_file "$home"
  printf '401' > "$home/curl-status"

  output="$(run_auth "$home" 2>&1)"

  [[ "$output" == *"[warn]"*"answered 401"*"ANTHROPIC_AUTH_TOKEN"* ]]
  [[ "$output" != *"accepted the key"* ]]
  [[ "$(git_value "$home" user.name)" == "Example Developer" ]]
}

# A redirect (to https, or to an SSO login page) says nothing about the key.
test_gateway_redirect_is_not_acceptance() {
  local home output
  home="$(auth_home gateway-redirect gateway)"
  gateway_file "$home"
  printf '302' > "$home/curl-status"

  output="$(run_auth "$home" 2>&1)"

  [[ "$output" == *"answered 302"* ]]
  [[ "$output" != *"accepted the key"* ]]
}

# Nothing answered (DNS, egress, TLS): the key was never judged, so the warning
# must not blame it — and curl's own reason must reach the user.
test_gateway_unreachable_is_not_blamed_on_the_key() {
  local home output
  home="$(auth_home gateway-unreachable gateway)"
  gateway_file "$home"
  printf '000' > "$home/curl-status"

  output="$(run_auth "$home" 2>&1)"

  [[ "$output" == *"Could not resolve host"* ]]
  [[ "$output" == *"no HTTP answer"*"not checked"* ]]
  [[ "$output" != *"answered 000"* && "$output" != *"accepted the key"* ]]
  [[ "$(git_value "$home" user.name)" == "Example Developer" ]]
}

# Without a token there is no key to accept, whatever the gateway answers.
test_gateway_without_a_token_says_so() {
  local home output
  home="$(auth_home gateway-notoken gateway)"
  printf "export ANTHROPIC_BASE_URL='https://gateway.example.com'\n" \
    > "$home/.config/rd/providers/gateway.env"

  output="$(run_auth "$home" 2>&1)"

  [[ "$output" == *"no ANTHROPIC_AUTH_TOKEN"* ]]
  [[ "$output" == *"answered 200 without a key"* ]]
  [[ "$output" != *"accepted the key"* ]]
  if grep -q Authorization "$home/curl-stdin"; then
    echo "rd-auth sent an Authorization header with no token configured" >&2
    return 1
  fi
}

# curl would guess http:// and send the key in the clear; Claude cannot use
# such a URL at all, so rd-auth refuses before any request.
test_gateway_url_without_scheme_fails_before_sending_the_key() {
  local home output
  home="$(auth_home gateway-noscheme gateway)"
  gateway_file "$home" "gateway.example.com"

  if output="$(run_auth "$home" 2>&1)"; then
    echo "rd-auth accepted a gateway URL with no scheme" >&2
    return 1
  fi
  [[ "$output" == *"no scheme"* ]]
  [[ ! -f "$home/curl-argv" ]]
}

test_gateway_plain_http_is_probed_with_a_warning() {
  local home output
  home="$(auth_home gateway-http gateway)"
  gateway_file "$home" "http://gateway.internal:4000"

  output="$(run_auth "$home" 2>&1)"

  [[ "$output" == *"plain http"* ]]
  grep -q -- "http://gateway.internal:4000/v1/models" "$home/curl-argv"
}

# A key holding ', " and \ survives bootstrap's quoting, rd-auth's unquoting
# and curl's config syntax byte for byte.
test_gateway_key_with_quotes_reaches_curl_exactly() {
  local home
  home="$(auth_home gateway-quotes gateway)"
  cat > "$home/.config/rd/providers/gateway.env" <<'EOF'
export ANTHROPIC_BASE_URL='https://gateway.example.com'
export ANTHROPIC_AUTH_TOKEN='sk-gw-it'\''s"x\y'
EOF

  run_auth "$home" >/dev/null 2>&1

  grep -qxF 'header = "Authorization: Bearer sk-gw-it'"'"'s\"x\\y"' "$home/curl-stdin"
}

test_gateway_without_base_url_fails() {
  local home output
  home="$(auth_home gateway-empty gateway)"
  printf 'export ANTHROPIC_AUTH_TOKEN=sk-gw-EXAMPLE\n' \
    > "$home/.config/rd/providers/gateway.env"

  if output="$(run_auth "$home" 2>&1)"; then
    echo "rd-auth accepted a gateway provider with no base URL" >&2
    return 1
  fi
  [[ "$output" == *"ANTHROPIC_BASE_URL"* ]]
  [[ ! -f "$home/curl-argv" ]]
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

# An unrelated broken host (a stale gitlab.com entry is the common case) makes
# `glab auth status` exit non-zero. Under `set -o pipefail` that used to send
# rd-auth down the login path even though the target host was authenticated —
# an interactive re-prompt at best, a hard failure in a non-interactive run.
test_existing_gitlab_login_is_detected_despite_another_broken_host() {
  local home
  home="$(auth_home already vertex)"

  run_auth "$home" >/dev/null

  grep -q -- "auth status --hostname gitlab.example.com" "$home/glab-log"
  ! grep -q -- "auth login" "$home/glab-log"
}

# Git matches a helper by scheme as well as host, so an https-scoped helper is
# never consulted for an http:// remote — the clone then dies asking for a
# username. Follow REPO_URL's scheme instead of assuming https.
test_http_forge_host_gets_an_http_scoped_helper() {
  local home
  home="$(auth_home httpforge vertex \
    'REPO_URL="http://gitlab.internal:8929/example/remote-dev.git"' \
    'GIT_USER_NAME="Example Developer"' \
    'GIT_USER_EMAIL="developer@example.com"')"

  run_auth "$home" >/dev/null

  [[ "$(git_value "$home" 'credential.http://gitlab.internal:8929.helper')" \
     == '!glab auth git-credential' ]]
  [[ -z "$(git_value "$home" 'credential.https://gitlab.internal:8929.helper')" ]]
}

test_github_remote_uses_gh() {
  local home
  home="$(auth_home github vertex \
    'REPO_URL="https://github.example.com/example/remote-dev.git"' \
    'FORGE="github"' \
    'GIT_USER_NAME="Example Developer"' \
    'GIT_USER_EMAIL="developer@example.com"')"

  run_auth "$home" >/dev/null

  grep -q -- "auth login --hostname github.example.com --git-protocol https --web" "$home/gh-log"
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

# glab's own git setup leaves an empty reset entry before its helper (here with
# an absolute path). A plain `git config key value` exits 5 on such a key, and
# set -e used to end rd-auth right there — before the Git author was set.
test_existing_multi_valued_gitlab_helper_is_kept() {
  local home key_file
  home="$(auth_home multivalue vertex)"
  key_file="$home/.gitconfig-$(printf '%s' 'credential.https://gitlab.example.com.helper' | tr -c 'A-Za-z0-9' '-')"
  printf '\n%s' '!/usr/bin/glab auth git-credential' > "$key_file"

  run_auth "$home" >/dev/null

  [[ "$(cat "$key_file")" == $'\n!/usr/bin/glab auth git-credential' ]]
  [[ "$(git_value "$home" user.name)" == "Example Developer" ]]
}

# Anything else on the key is replaced, as before.
test_foreign_gitlab_helper_is_replaced() {
  local home
  home="$(auth_home foreignhelper vertex)"
  printf '%s' 'store' \
    > "$home/.gitconfig-$(printf '%s' 'credential.https://gitlab.example.com.helper' | tr -c 'A-Za-z0-9' '-')"

  run_auth "$home" >/dev/null

  [[ "$(git_value "$home" 'credential.https://gitlab.example.com.helper')" \
     == '!glab auth git-credential' ]]
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
test_anthropic_subscription_keeps_one_token_from_a_repeated_paste
test_onboarding_is_marked_done
test_anthropic_subscription_rejects_a_bad_paste
test_anthropic_api_key_needs_no_login
test_gateway_checks_the_key_without_exposing_it
test_gateway_refusing_the_key_warns_but_continues
test_gateway_redirect_is_not_acceptance
test_gateway_unreachable_is_not_blamed_on_the_key
test_gateway_without_a_token_says_so
test_gateway_url_without_scheme_fails_before_sending_the_key
test_gateway_plain_http_is_probed_with_a_warning
test_gateway_key_with_quotes_reaches_curl_exactly
test_gateway_without_base_url_fails
test_provider_flag_overrides_the_default
test_gitlab_credential_helper_is_host_scoped
test_existing_gitlab_login_is_detected_despite_another_broken_host
test_http_forge_host_gets_an_http_scoped_helper
test_github_remote_uses_gh
test_github_dot_com_is_detected_without_forge_key
test_forge_flag_overrides_detection
test_ambiguous_host_without_a_tty_fails
test_existing_multi_valued_gitlab_helper_is_kept
test_foreign_gitlab_helper_is_replaced
test_migrates_legacy_global_credential_helper
echo "rd-auth tests passed"
