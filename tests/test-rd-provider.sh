#!/usr/bin/env bash
# rd-start provider resolution: default, override, validation, mismatch —
# plus the provider column rd-list exposes to rd-tui.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

BIN="$TEST_ROOT/bin"
rd_test_install_stubs "$BIN"

# A HOME with a repo to start sessions in and two configured providers.
new_home() {
  local home="$TEST_ROOT/$1/home"
  mkdir -p "$home/projects" "$home/.config/rd/providers"
  rd_test_new_repo "$home/projects/demo"
  printf 'export CLAUDE_CODE_USE_VERTEX=1\n' > "$home/.config/rd/providers/vertex.env"
  printf 'export CLAUDE_CODE_USE_BEDROCK=1\n' > "$home/.config/rd/providers/bedrock.env"
  printf 'vertex\n' > "$home/.config/rd/provider"
  printf '%s' "$home"
}

run_rd() {
  local home="$1" script="$2"
  shift 2
  HOME="$home" PATH="$BIN:$PATH" \
    TMUX_STATE="$home/tmux-state" TMUX_LOG="$home/tmux-log" \
    "$ROOT_DIR/bin/$script" "$@"
}

session_env() { cat "$1/tmux-state.claude-demo.env" 2>/dev/null || true; }
session_option() { cat "$1/tmux-state.claude-demo.rd_provider" 2>/dev/null || true; }

test_default_provider_is_recorded_without_env_injection() {
  local home
  home="$(new_home default)"
  run_rd "$home" rd-start demo >/dev/null

  [[ "$(session_option "$home")" == "vertex" ]]
  # No --provider means the login shell reads the default file itself, so
  # nothing needs to cross the tmux boundary.
  [[ -z "$(session_env "$home")" ]]
}

test_provider_override_crosses_the_tmux_boundary() {
  local home
  home="$(new_home override)"
  run_rd "$home" rd-start demo --provider bedrock >/dev/null

  [[ "$(session_env "$home")" == "RD_PROVIDER=bedrock" ]]
  [[ "$(session_option "$home")" == "bedrock" ]]
}

test_rejects_unconfigured_provider() {
  local home output
  home="$(new_home unknown)"

  if output="$(run_rd "$home" rd-start demo --provider nope 2>&1)"; then
    echo "rd-start accepted an unconfigured provider" >&2
    return 1
  fi
  [[ "$output" == *"nope"* ]]
  [[ "$output" == *"vertex"* && "$output" == *"bedrock"* ]]
}

test_rejects_provider_change_on_running_session() {
  local home output
  home="$(new_home mismatch)"
  run_rd "$home" rd-start demo --provider bedrock >/dev/null

  if output="$(run_rd "$home" rd-start demo --provider vertex 2>&1)"; then
    echo "rd-start accepted a provider change on a running session" >&2
    return 1
  fi
  [[ "$output" == *"bedrock"* && "$output" == *"vertex"* ]]
  [[ "$output" == *"rd-stop"* ]]
}

test_reusing_a_session_keeps_its_provider() {
  local home
  home="$(new_home reuse)"
  run_rd "$home" rd-start demo --provider bedrock >/dev/null
  run_rd "$home" rd-start demo >/dev/null

  [[ "$(session_option "$home")" == "bedrock" ]]
}

# A VM provisioned before provider files existed must keep working: no config
# means no injection and no recorded provider, not a refusal to start.
test_unconfigured_vm_still_starts_sessions() {
  local home
  home="$TEST_ROOT/legacy/home"
  mkdir -p "$home/projects"
  rd_test_new_repo "$home/projects/demo"

  run_rd "$home" rd-start demo >/dev/null

  [[ -z "$(session_option "$home")" ]]
  [[ -z "$(session_env "$home")" ]]
}

# But an explicit --provider on such a VM is a mistake worth reporting.
test_unconfigured_vm_rejects_explicit_provider() {
  local home output
  home="$TEST_ROOT/legacy-explicit/home"
  mkdir -p "$home/projects"
  rd_test_new_repo "$home/projects/demo"

  if output="$(run_rd "$home" rd-start demo --provider bedrock 2>&1)"; then
    echo "rd-start accepted --provider on a VM with no provider config" >&2
    return 1
  fi
  [[ "$output" == *"bedrock"* ]]
}

test_rd_list_reports_the_provider() {
  local home porcelain
  home="$(new_home listing)"
  run_rd "$home" rd-start demo --provider bedrock >/dev/null

  porcelain="$(run_rd "$home" rd-list --porcelain)"
  # state, project, session, branch, dir, created, provider
  [[ "$(cut -f7 <<< "$porcelain")" == "bedrock" ]]
}

test_default_provider_is_recorded_without_env_injection
test_provider_override_crosses_the_tmux_boundary
test_rejects_unconfigured_provider
test_rejects_provider_change_on_running_session
test_reusing_a_session_keeps_its_provider
test_unconfigured_vm_still_starts_sessions
test_unconfigured_vm_rejects_explicit_provider
test_rd_list_reports_the_provider
echo "rd-start provider tests passed"
