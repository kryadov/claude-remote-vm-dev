#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

rd_test_install_stubs "$TEST_ROOT/bin"

new_repo() {
  rd_test_new_repo "$1"
}

test_named_session_creates_isolated_bugfix_worktree() {
  local home="$TEST_ROOT/named/home"
  local repo="$home/projects/backend"
  local worktree="$home/worktrees/backend/login-timeout"
  local log="$TEST_ROOT/named/tmux.log"
  local state="$TEST_ROOT/named/tmux.state"
  mkdir -p "$home/projects"
  : > "$log"
  : > "$state"
  new_repo "$repo"

  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo" \
      --session login-timeout --type bugfix >/dev/null

  [[ "$(git -C "$worktree" branch --show-current)" == "bugfix/login-timeout" ]]
  grep -q 'new-session .*claude-backend--login-timeout .*login-timeout' "$log"
}

test_named_session_lifecycle_and_listing() {
  local home="$TEST_ROOT/lifecycle/home"
  local repo="$home/projects/backend"
  local log="$TEST_ROOT/lifecycle/tmux.log"
  local state="$TEST_ROOT/lifecycle/tmux.state"
  local output
  local restart_output
  mkdir -p "$home/projects"
  : > "$log"
  : > "$state"
  new_repo "$repo"

  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo" >/dev/null
  restart_output="$(HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo")"
  [[ "$restart_output" == *"rd-attach backend"* ]]
  [[ "$restart_output" != *"--session default"* ]]
  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo" --session search >/dev/null
  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-attach" backend --session search
  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-stop" backend --session search >/dev/null

  output="$(HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-list")"
  [[ "$output" == *"SESSION"* ]]
  [[ "$output" == *"backend"*"default"* ]]
  grep -q 'attach .*claude-backend--search' "$log"
  grep -q 'kill-session .*claude-backend--search' "$log"
}

test_rejects_unsafe_session_names() {
  local home="$TEST_ROOT/unsafe/home"
  local repo="$home/projects/backend"
  local log="$TEST_ROOT/unsafe/tmux.log"
  local state="$TEST_ROOT/unsafe/tmux.state"
  local output
  mkdir -p "$home/projects"
  : > "$log"
  : > "$state"
  new_repo "$repo"

  if output="$(HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo" --session nested/name 2>&1)"; then
    echo "rd-start unexpectedly accepted a slash in the session name" >&2
    return 1
  fi
  [[ "$output" == *"invalid session name"* ]]
}

test_remove_is_safe_and_preserves_branch_by_default() {
  local home="$TEST_ROOT/remove/home"
  local repo="$home/projects/backend"
  local worktree="$home/worktrees/backend/cleanup"
  local log="$TEST_ROOT/remove/tmux.log"
  local state="$TEST_ROOT/remove/tmux.state"
  local output
  mkdir -p "$home/projects"
  : > "$log"
  : > "$state"
  new_repo "$repo"

  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo" --session cleanup >/dev/null
  if output="$(HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-remove" backend --session cleanup 2>&1)"; then
    echo "rd-remove unexpectedly removed a running session" >&2
    return 1
  fi
  [[ "$output" == *"still running"* ]]

  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-stop" backend --session cleanup >/dev/null
  printf 'dirty\n' > "$worktree/uncommitted.txt"
  if output="$(HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-remove" backend --session cleanup 2>&1)"; then
    echo "rd-remove unexpectedly removed a dirty worktree" >&2
    return 1
  fi
  [[ "$output" == *"uncommitted changes"* ]]

  rm "$worktree/uncommitted.txt"
  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-remove" backend --session cleanup >/dev/null
  [[ ! -e "$worktree" ]]
  git -C "$repo" show-ref --verify --quiet refs/heads/feature/cleanup
}

test_remove_can_delete_a_merged_branch() {
  local home="$TEST_ROOT/delete-branch/home"
  local repo="$home/projects/backend"
  local log="$TEST_ROOT/delete-branch/tmux.log"
  local state="$TEST_ROOT/delete-branch/tmux.state"
  mkdir -p "$home/projects"
  : > "$log"
  : > "$state"
  new_repo "$repo"

  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo" --session merged >/dev/null
  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-stop" backend --session merged >/dev/null
  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-remove" backend --session merged --delete-branch >/dev/null

  ! git -C "$repo" show-ref --verify --quiet refs/heads/feature/merged
}

test_attach_here_finds_session_from_worktree() {
  local home="$TEST_ROOT/attach-here/home"
  local repo="$home/projects/backend"
  local worktree="$home/worktrees/backend/search"
  local log="$TEST_ROOT/attach-here/tmux.log"
  local state="$TEST_ROOT/attach-here/tmux.state"
  mkdir -p "$home/projects"
  : > "$log"
  : > "$state"
  new_repo "$repo"

  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo" --session search >/dev/null
  (
    cd "$worktree"
    HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
      "$ROOT_DIR/bin/rd-attach-here"
  )
  grep -q 'attach .*claude-backend--search' "$log"
}

test_vscode_init_adds_task_without_losing_existing_tasks() {
  local repo="$TEST_ROOT/vscode/repo"
  local tasks="$repo/.vscode/tasks.json"
  mkdir -p "$repo/.vscode"
  cat > "$tasks" <<'EOF'
{
  // Existing project task must survive initialization.
  "version": "2.0.0",
  "tasks": [
    { "label": "Existing task", "type": "shell", "command": "true" },
  ]
}
EOF

  "$ROOT_DIR/bin/rd-vscode-init" "$repo" >/dev/null
  "$ROOT_DIR/bin/rd-vscode-init" "$repo" >/dev/null

  python3 - "$tasks" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
assert "Existing project task must survive initialization." in text
assert text.count('"label": "Existing task"') == 1
assert text.count('"label": "Remote Dev: Attach Claude"') == 1
assert '"command": "rd-attach-here"' in text
assert '"runOn": "folderOpen"' in text
PY
}

test_restart_reuses_existing_worktree_branch_without_repeating_type() {
  local home="$TEST_ROOT/restart/home"
  local repo="$home/projects/backend"
  local log="$TEST_ROOT/restart/tmux.log"
  local state="$TEST_ROOT/restart/tmux.state"
  mkdir -p "$home/projects"
  : > "$log"
  : > "$state"
  new_repo "$repo"

  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo" --session login --type bugfix >/dev/null
  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-stop" backend --session login >/dev/null
  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo" --session login >/dev/null

  [[ "$(git -C "$home/worktrees/backend/login" branch --show-current)" == "bugfix/login" ]]
}

test_connect_forwards_named_session_options_to_start_and_attach() {
  local helper_dir="$TEST_ROOT/connect/helper"
  local ssh_log="$TEST_ROOT/connect/ssh.log"
  mkdir -p "$helper_dir"
  cp "$ROOT_DIR/connect.sh" "$helper_dir/connect.sh"
  cat > "$helper_dir/rd.env" <<'EOF'
VM_IP="192.0.2.10"
VM_USER="developer"
SSH_KEY="/tmp/example.key"
EOF

  SSH_LOG="$ssh_log" PATH="$TEST_ROOT/bin:$PATH" \
    "$helper_dir/connect.sh" backend --session search --type bugfix

  grep -q 'rd-start.*backend.*--session.*search.*--type.*bugfix' "$ssh_log"
  grep -q 'rd-attach.*backend.*--session.*search' "$ssh_log"
}

test_detects_legacy_default_name_collision_without_breaking_legacy_project() {
  local home="$TEST_ROOT/collision/home"
  local repo="$home/projects/foo--bar"
  local log="$TEST_ROOT/collision/tmux.log"
  local state="$TEST_ROOT/collision/tmux.state"
  local output
  mkdir -p "$home/projects"
  : > "$log"
  : > "$state"
  new_repo "$repo"

  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" foo--bar "$repo" >/dev/null
  if output="$(HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" foo "$repo" --session bar 2>&1)"; then
    echo "rd-start unexpectedly reused a colliding legacy default session" >&2
    return 1
  fi
  [[ "$output" == *"tmux name collision"* ]]
}

test_existing_default_session_gets_metadata_backfilled() {
  local home="$TEST_ROOT/backfill/home"
  local repo="$home/projects/backend"
  local log="$TEST_ROOT/backfill/tmux.log"
  local state="$TEST_ROOT/backfill/tmux.state"
  mkdir -p "$home/projects"
  : > "$log"
  new_repo "$repo"
  printf 'claude-backend\t%s\tdetached\t%s\n' "$(date +%s)" "$repo" > "$state"

  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo" >/dev/null
  [[ "$(cat "$state.claude-backend.rd_project")" == "backend" ]]
  [[ "$(cat "$state.claude-backend.rd_session")" == "default" ]]
  [[ "$(cat "$state.claude-backend.rd_worktree")" == "$(cd "$repo" && pwd -P)" ]]
}

test_relative_default_path_is_stored_canonically() {
  local home="$TEST_ROOT/canonical/home"
  local repo="$home/source"
  local log="$TEST_ROOT/canonical/tmux.log"
  local state="$TEST_ROOT/canonical/tmux.state"
  mkdir -p "$home"
  : > "$log"
  : > "$state"
  new_repo "$repo"

  (
    cd "$repo"
    HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
      "$ROOT_DIR/bin/rd-start" backend . >/dev/null
  )
  [[ "$(cat "$state.claude-backend.rd_worktree")" == "$(cd "$repo" && pwd -P)" ]]
}

test_existing_metadata_is_not_overwritten_from_active_pane() {
  local home="$TEST_ROOT/preserve-metadata/home"
  local repo="$home/projects/backend"
  local log="$TEST_ROOT/preserve-metadata/tmux.log"
  local state="$TEST_ROOT/preserve-metadata/tmux.state"
  mkdir -p "$home/projects"
  : > "$log"
  : > "$state"
  new_repo "$repo"

  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo" >/dev/null
  awk -F '\t' 'BEGIN { OFS="\t" } { $4="/tmp"; print }' "$state" > "$state.tmp"
  mv "$state.tmp" "$state"
  HOME="$home" TMUX_LOG="$log" TMUX_STATE="$state" PATH="$TEST_ROOT/bin:$PATH" \
    "$ROOT_DIR/bin/rd-start" backend "$repo" >/dev/null

  [[ "$(cat "$state.claude-backend.rd_worktree")" == "$(cd "$repo" && pwd -P)" ]]
}

test_named_session_creates_isolated_bugfix_worktree
test_named_session_lifecycle_and_listing
test_rejects_unsafe_session_names
test_remove_is_safe_and_preserves_branch_by_default
test_remove_can_delete_a_merged_branch
test_attach_here_finds_session_from_worktree
test_vscode_init_adds_task_without_losing_existing_tasks
test_restart_reuses_existing_worktree_branch_without_repeating_type
test_connect_forwards_named_session_options_to_start_and_attach
test_detects_legacy_default_name_collision_without_breaking_legacy_project
test_existing_default_session_gets_metadata_backfilled
test_relative_default_path_is_stored_canonically
test_existing_metadata_is_not_overwritten_from_active_pane
echo "rd session tests passed"
