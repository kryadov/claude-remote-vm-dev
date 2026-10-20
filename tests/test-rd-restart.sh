#!/usr/bin/env bash
# rd-claude / rd-claude-hook / rd-restart / rd-update, and the rd-list columns
# they feed: resume the right conversation, never kill a turn in progress.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

BIN="$TEST_ROOT/bin"
rd_test_install_stubs "$BIN"

# npm: `view` answers $dir/latest, `ls -g` succeeds unless $dir/native exists,
# `install -g pkg@v` installs v ('broken' if $dir/broken lists it).
cat > "$BIN/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir="$CLAUDE_STUB_DIR"
printf 'npm %s\n' "$*" >> "$dir/log"
case "$1" in
  view) cat "$dir/latest" ;;
  ls) [[ ! -e "$dir/native" ]] ;;
  install)
    version="${3##*@}"
    if grep -qx "$version" "$dir/broken" 2>/dev/null; then
      echo broken > "$dir/version"
    else
      echo "$version" > "$dir/version"
    fi
    ;;
esac
EOF
cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$CLAUDE_STUB_DIR/log"
exec "$@"
EOF
chmod +x "$BIN/npm" "$BIN/sudo"

HOME_DIR=""

# A HOME with a 'demo' repo, Claude 2.1.1 installed and 2.1.2 published.
setup_case() {
  HOME_DIR="$TEST_ROOT/$1/home"
  mkdir -p "$HOME_DIR/projects" "$HOME_DIR/claude-stub"
  : > "$HOME_DIR/tmux-state"
  : > "$HOME_DIR/tmux-log"
  echo 2.1.1 > "$HOME_DIR/claude-stub/version"
  echo 2.1.2 > "$HOME_DIR/claude-stub/latest"
  rd_test_new_repo "$HOME_DIR/projects/demo"
}

rd() {
  local script="$1"
  shift
  HOME="$HOME_DIR" PATH="$BIN:$PATH" \
    TMUX_STATE="$HOME_DIR/tmux-state" TMUX_LOG="$HOME_DIR/tmux-log" \
    CLAUDE_STUB_DIR="$HOME_DIR/claude-stub" \
    "$ROOT_DIR/bin/$script" "$@"
}

# Runs the hook as Claude would, from inside the demo session's pane.
hook() {
  local event="$1" input="${2:-{\}}"
  printf '%s' "$input" | TMUX_PANE="=claude-demo:" rd rd-claude-hook "$event"
}

option() { cat "$HOME_DIR/tmux-state.claude-demo.$1" 2>/dev/null || true; }
claude_log() { cat "$HOME_DIR/claude-stub/log" 2>/dev/null || true; }
# The tmux stub logs arguments with %q; undo the escaped spaces for matching.
last_send_keys() { grep '^send-keys' "$HOME_DIR/tmux-log" | tail -1 | sed -e 's/ *$//' -e 's/\\ / /g'; }

transcript() {
  mkdir -p "$HOME_DIR/.claude/projects/-home-demo"
  : > "$HOME_DIR/.claude/projects/-home-demo/$1.jsonl"
}

ID="0b7e7c38-5d0f-4c1e-9a55-3f1d2e4b6a70"

test_hook_tracks_conversation_and_state() {
  local output
  setup_case hook
  rd rd-start demo >/dev/null

  output="$(hook session-start "{\"session_id\": \"$ID\", \"source\": \"startup\"}")"
  [[ -z "$output" ]] || { echo "hook printed into Claude's context: $output" >&2; return 1; }
  [[ "$(option rd_claude_session)" == "$ID" ]]
  [[ "$(option rd_claude_state)" == "idle" ]]
  [[ "$(option rd_claude_state_at)" =~ ^[0-9]+$ ]]

  [[ -z "$(hook prompt)" ]]
  [[ "$(option rd_claude_state)" == "busy" ]]
  hook stop
  [[ "$(option rd_claude_state)" == "idle" ]]
  hook session-end
  [[ "$(option rd_claude_state)" == "exited" ]]
}

test_hook_rejects_an_id_that_is_not_plain() {
  setup_case hook-id
  rd rd-start demo >/dev/null
  hook session-start '{"session_id": "x; rm -rf ~"}'
  [[ -z "$(option rd_claude_session)" ]]
}

test_hook_outside_tmux_does_nothing() {
  setup_case hook-notmux
  printf '{"session_id": "%s"}' "$ID" | rd rd-claude-hook session-start
  [[ ! -s "$HOME_DIR/tmux-log" ]]
}

test_rd_claude_launches_with_hooks_and_records_version() {
  local settings
  setup_case launcher
  rd rd-start demo >/dev/null
  TMUX_PANE="=claude-demo:" rd rd-claude --continue

  settings="$HOME_DIR/.config/rd/claude-settings.json"
  for event in SessionStart UserPromptSubmit Stop SessionEnd; do
    grep -q "\"$event\"" "$settings" || { echo "settings lack $event" >&2; return 1; }
  done
  grep -q "rd-claude-hook session-start" "$settings"
  [[ "$(claude_log)" == *"--dangerously-skip-permissions --settings $settings --continue"* ]]
  [[ "$(option rd_claude_version)" == "2.1.1" ]]
  [[ "$(option rd_claude_pane)" == "=claude-demo:" ]]
  # Its own updater cannot write the npm prefix; rd-update owns updates.
  [[ "$(cat "$HOME_DIR/claude-stub/env")" == "DISABLE_AUTOUPDATER=1" ]]
}

test_rd_start_launches_through_rd_claude() {
  setup_case start
  rd rd-start demo >/dev/null
  [[ "$(last_send_keys)" == *"/bin/rd-claude C-m" ]]
}

test_restart_refuses_unknown_state_with_exit_3() {
  local status=0 output
  setup_case unknown
  rd rd-start demo >/dev/null
  output="$(rd rd-restart demo 2>&1)" || status=$?
  [[ "$status" -eq 3 ]] || { echo "expected exit 3, got $status" >&2; return 1; }
  [[ "$output" == *"unknown"* && "$output" == *"--force"* ]]
  ! grep -q '^respawn-pane' "$HOME_DIR/tmux-log"
}

test_restart_refuses_busy_session() {
  local status=0 output
  setup_case busy
  rd rd-start demo >/dev/null
  hook session-start "{\"session_id\": \"$ID\"}"
  hook prompt
  output="$(rd rd-restart demo 2>&1)" || status=$?
  [[ "$status" -eq 3 && "$output" == *"busy"* ]]
}

test_restart_resumes_the_recorded_conversation() {
  setup_case resume
  rd rd-start demo >/dev/null
  hook session-start "{\"session_id\": \"$ID\"}"
  transcript "$ID"
  rd rd-restart demo >/dev/null

  grep -q "^respawn-pane -t =claude-demo: -k -c $HOME_DIR/projects/demo" "$HOME_DIR/tmux-log"
  [[ "$(last_send_keys)" == *"/bin/rd-claude --resume $ID C-m" ]]
  # Cleared until the new Claude's SessionStart reports in.
  [[ -z "$(option rd_claude_state)" ]]
}

test_restart_force_on_legacy_session_continues() {
  local worktree
  setup_case legacy
  rd rd-start demo >/dev/null
  # Claude files a worktree's transcripts under its path with non-alnum -> '-'.
  worktree="$(option rd_worktree)"
  mkdir -p "$HOME_DIR/.claude/projects/${worktree//[^A-Za-z0-9]/-}"
  : > "$HOME_DIR/.claude/projects/${worktree//[^A-Za-z0-9]/-}/old.jsonl"
  rd rd-restart demo --force >/dev/null
  [[ "$(last_send_keys)" == *"/bin/rd-claude --continue C-m" ]]
}

# --continue with nothing to continue makes Claude print "No conversation
# found" and exit, leaving the session at a bare shell.
test_restart_legacy_without_conversations_starts_fresh() {
  setup_case legacy-empty
  rd rd-start demo >/dev/null
  rd rd-restart demo --force >/dev/null
  [[ "$(last_send_keys)" == *"/bin/rd-claude C-m" ]]
}

test_stop_failure_ends_the_turn() {
  local settings
  setup_case stop-failure
  rd rd-start demo >/dev/null
  TMUX_PANE="=claude-demo:" rd rd-claude
  settings="$HOME_DIR/.config/rd/claude-settings.json"
  grep -q '"StopFailure": .*rd-claude-hook stop' "$settings"
  hook prompt
  hook stop
  [[ "$(option rd_claude_state)" == "idle" ]]
}

test_restart_without_transcript_starts_fresh() {
  local output
  setup_case gone
  rd rd-start demo >/dev/null
  hook session-start "{\"session_id\": \"$ID\"}"
  output="$(rd rd-restart demo 2>&1)"
  [[ "$output" == *"no transcript"* ]]
  [[ "$(last_send_keys)" == *"/bin/rd-claude C-m" ]]
}

test_restart_rejects_stopped_session() {
  local status=0 output
  setup_case stopped
  output="$(rd rd-restart demo 2>&1)" || status=$?
  [[ "$status" -eq 1 && "$output" == *"rd-start demo"* ]]
}

test_restart_named_session_checks_metadata() {
  setup_case named
  rd rd-start demo --session search >/dev/null
  TMUX_PANE="=claude-demo--search:" rd rd-claude-hook session-start <<< "{\"session_id\": \"$ID\"}"
  rd rd-restart demo --session search >/dev/null
  grep -q "^respawn-pane -t =claude-demo--search: -k -c $HOME_DIR/worktrees/demo/search" "$HOME_DIR/tmux-log"
}

test_update_is_a_noop_when_current() {
  local output
  setup_case noop
  echo 2.1.1 > "$HOME_DIR/claude-stub/latest"
  output="$(rd rd-update)"
  [[ "$output" == *"already on 2.1.1"* ]]
  ! grep -q "install" "$HOME_DIR/claude-stub/log"
}

test_update_installs_latest_through_sudo_npm() {
  setup_case npm
  rd rd-update >/dev/null
  grep -q "^sudo npm install -g @anthropic-ai/claude-code@2.1.2$" "$HOME_DIR/claude-stub/log"
  [[ "$(cat "$HOME_DIR/claude-stub/version")" == "2.1.2" ]]
}

test_update_rolls_back_a_broken_release() {
  local status=0 output
  setup_case broken
  echo 2.1.2 > "$HOME_DIR/claude-stub/broken"
  output="$(rd rd-update 2>&1)" || status=$?
  [[ "$status" -eq 1 && "$output" == *"rolling back to 2.1.1"* ]]
  [[ "$(cat "$HOME_DIR/claude-stub/version")" == "2.1.1" ]]
}

test_update_uses_claude_install_for_native_installs() {
  setup_case native
  touch "$HOME_DIR/claude-stub/native"
  rd rd-update 2.1.5 >/dev/null
  grep -q "^install 2.1.5$" "$HOME_DIR/claude-stub/log"
  ! grep -q "^sudo" "$HOME_DIR/claude-stub/log"
}

test_restart_update_installs_before_restarting() {
  setup_case chained
  rd rd-start demo >/dev/null
  hook session-start "{\"session_id\": \"$ID\"}"
  transcript "$ID"
  rd rd-restart demo --update >/dev/null
  [[ "$(cat "$HOME_DIR/claude-stub/version")" == "2.1.2" ]]
  [[ "$(last_send_keys)" == *"--resume $ID C-m" ]]
  # Not left 'outdated' for a listing taken before the new Claude reports in.
  [[ "$(option rd_claude_version)" == "2.1.2" ]]
}

test_rd_list_reports_activity_version_and_outdated() {
  local row human
  setup_case listing
  rd rd-start demo >/dev/null
  TMUX_PANE="=claude-demo:" rd rd-claude
  hook prompt
  echo 2.1.2 > "$HOME_DIR/claude-stub/version"

  row="$(rd rd-list --porcelain)"
  # ... provider(7), activity(8), claude(9), update(10)
  [[ "$(cut -f8 <<< "$row")" == "busy" ]]
  [[ "$(cut -f9 <<< "$row")" == "2.1.1" ]]
  [[ "$(cut -f10 <<< "$row")" == "outdated" ]]

  human="$(rd rd-list)"
  [[ "$human" == *"ACTIVITY"*"CLAUDE"* && "$human" == *"2.1.1*"* ]]
  [[ "$human" == *"older than the installed Claude 2.1.2"* ]]
}

# A session with no provider (legacy VM) but a known activity must not shift
# columns: a tab IFS would collapse the empty provider field.
test_rd_list_keeps_columns_with_empty_provider() {
  local row
  setup_case empty-provider
  rd rd-start demo >/dev/null
  hook stop
  row="$(rd rd-list --porcelain)"
  [[ -z "$(cut -f7 <<< "$row")" ]]
  [[ "$(cut -f8 <<< "$row")" == "idle" ]]
}

test_hook_tracks_conversation_and_state
test_hook_rejects_an_id_that_is_not_plain
test_hook_outside_tmux_does_nothing
test_rd_claude_launches_with_hooks_and_records_version
test_rd_start_launches_through_rd_claude
test_restart_refuses_unknown_state_with_exit_3
test_restart_refuses_busy_session
test_restart_resumes_the_recorded_conversation
test_restart_force_on_legacy_session_continues
test_restart_legacy_without_conversations_starts_fresh
test_stop_failure_ends_the_turn
test_restart_without_transcript_starts_fresh
test_restart_rejects_stopped_session
test_restart_named_session_checks_metadata
test_update_is_a_noop_when_current
test_update_installs_latest_through_sudo_npm
test_update_rolls_back_a_broken_release
test_update_uses_claude_install_for_native_installs
test_restart_update_installs_before_restarting
test_rd_list_reports_activity_version_and_outdated
test_rd_list_keeps_columns_with_empty_provider
echo "rd-restart tests passed"
