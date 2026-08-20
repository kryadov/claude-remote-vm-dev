#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

rd_test_install_stubs "$TEST_ROOT/bin"

HOME_DIR=""
TMUX_LOG_FILE=""
TMUX_STATE_FILE=""

# Creates an isolated HOME with a 'backend' repo, and points the following rd()
# calls at it.
setup_case() {
  local name="$1"
  HOME_DIR="$TEST_ROOT/$name/home"
  TMUX_LOG_FILE="$TEST_ROOT/$name/tmux.log"
  TMUX_STATE_FILE="$TEST_ROOT/$name/tmux.state"
  mkdir -p "$HOME_DIR/projects"
  : > "$TMUX_LOG_FILE"
  : > "$TMUX_STATE_FILE"
  rd_test_new_repo "$HOME_DIR/projects/backend"
}

rd() {
  local script="$1"
  shift
  HOME="$HOME_DIR" TMUX_LOG="$TMUX_LOG_FILE" TMUX_STATE="$TMUX_STATE_FILE" \
    PATH="$TEST_ROOT/bin:$PATH" "$ROOT_DIR/bin/$script" "$@"
}

# Feeds keystrokes to rd-tui and prints the frames it rendered.
tui() {
  local keys="$1"
  printf '%b' "$keys" | rd rd-tui
}

# A running default session plus a stopped named one.
setup_running_and_stopped() {
  setup_case "$1"
  rd rd-start backend >/dev/null
  rd rd-start backend --session search >/dev/null
  rd rd-stop backend --session search >/dev/null
}

test_porcelain_lists_running_and_stopped_sessions() {
  local all running
  setup_running_and_stopped porcelain

  all="$(rd rd-list --porcelain --all)"
  [[ "$all" == *$'detached\tbackend\tdefault\tmain\t'* ]] || {
    echo "porcelain is missing the running default session: $all" >&2
    return 1
  }
  [[ "$all" == *$'stopped\tbackend\tsearch\tfeature/search\t'* ]] || {
    echo "porcelain is missing the stopped named session: $all" >&2
    return 1
  }

  # Without --all the stopped worktree must not appear.
  running="$(rd rd-list --porcelain)"
  [[ "$running" != *"stopped"* ]] || {
    echo "porcelain without --all leaked a stopped session: $running" >&2
    return 1
  }

  # The human table keeps working and shows both states.
  [[ "$(rd rd-list --all)" == *"PROJECT"*"stopped"* ]]
}

test_lists_running_and_stopped_and_quits_on_q() {
  local output
  setup_running_and_stopped listing

  output="$(tui 'q')"
  [[ "$output" == *"PROJECT"* ]]
  [[ "$output" == *"backend"* ]]
  [[ "$output" == *"default"* ]]
  [[ "$output" == *"search"* ]]
  [[ "$output" == *"stopped"* ]]
}

test_enter_attaches_to_the_selected_running_session() {
  setup_running_and_stopped attach
  tui '\n' >/dev/null

  grep -q 'attach -t =claude-backend ' "$TMUX_LOG_FILE" || {
    echo "rd-tui did not attach to the highlighted session" >&2
    return 1
  }
}

test_enter_restarts_a_stopped_session_before_attaching() {
  setup_running_and_stopped restart
  # Down moves to backend/search, which is stopped.
  tui '\033[B\n' >/dev/null

  grep -q 'new-session .*claude-backend--search' "$TMUX_LOG_FILE" || {
    echo "rd-tui did not restart the stopped session" >&2
    return 1
  }
  grep -q 'attach -t =claude-backend--search' "$TMUX_LOG_FILE"
}

test_s_stops_the_session_after_confirmation() {
  local output
  setup_running_and_stopped stop

  output="$(tui 'syq')"
  grep -q 'kill-session -t =claude-backend ' "$TMUX_LOG_FILE" || {
    echo "rd-tui did not stop the highlighted session" >&2
    return 1
  }
  [[ "$output" == *"Stopped backend/default."* ]]
}

test_n_declines_to_stop_when_not_confirmed() {
  local output
  setup_running_and_stopped decline

  # The setup already stopped backend/search, so look for the default session
  # specifically — 'kill-session' on its own would match that earlier call.
  output="$(tui 'snq')"
  if grep -q 'kill-session -t =claude-backend ' "$TMUX_LOG_FILE"; then
    echo "rd-tui stopped a session without confirmation" >&2
    return 1
  fi
  [[ "$output" == *"Cancelled."* ]]
}

test_x_removes_a_stopped_worktree_and_keeps_the_branch() {
  local output
  setup_running_and_stopped remove

  output="$(tui '\033[Bxyq')"
  [[ ! -e "$HOME_DIR/worktrees/backend/search" ]] || {
    echo "rd-tui did not remove the stopped worktree" >&2
    return 1
  }
  git -C "$HOME_DIR/projects/backend" show-ref --verify --quiet refs/heads/feature/search
  [[ "$output" == *"Removed worktree of backend/search."* ]]
}

test_x_refuses_to_remove_a_running_session() {
  local output
  setup_running_and_stopped remove_running

  output="$(tui 'xq')"
  [[ "$output" == *"Stop backend/default before removing its worktree."* ]]
  [[ -d "$HOME_DIR/projects/backend" ]]
}

test_new_session_wizard_starts_and_attaches() {
  setup_case wizard
  # n -> pick 'backend' (enter) -> name 'wizard' -> pick 'bugfix' (down, enter)
  tui 'n\nwizard\n\033[B\n' >/dev/null

  [[ "$(git -C "$HOME_DIR/worktrees/backend/wizard" branch --show-current)" == "bugfix/wizard" ]] || {
    echo "the wizard did not create a bugfix worktree" >&2
    return 1
  }
  grep -q 'attach -t =claude-backend--wizard' "$TMUX_LOG_FILE"
}

test_new_session_wizard_defaults_to_the_default_session() {
  setup_case wizard_default
  # n -> pick 'backend' (enter) -> empty name -> default session, no type prompt
  tui 'n\n\n' >/dev/null

  grep -q 'new-session .*claude-backend ' "$TMUX_LOG_FILE" || {
    echo "the wizard did not start the default session" >&2
    return 1
  }
  grep -q 'attach -t =claude-backend ' "$TMUX_LOG_FILE"
}

test_long_names_stay_aligned_and_long_branches_are_truncated() {
  local frame header row prefix header_pos row_pos
  HOME_DIR="$TEST_ROOT/wide/home"
  TMUX_LOG_FILE="$TEST_ROOT/wide/tmux.log"
  TMUX_STATE_FILE="$TEST_ROOT/wide/tmux.state"
  mkdir -p "$HOME_DIR/projects"
  : > "$TMUX_LOG_FILE"
  : > "$TMUX_STATE_FILE"
  # A project name wider than the old fixed 18-char column, and a branch name
  # wider than the 30-char cap.
  rd_test_new_repo "$HOME_DIR/projects/project1"
  rd rd-start project1 --session parity \
    --branch feature/reranker-parity-and-support-ttsp >/dev/null

  frame="$(tui 'q' | sed 's/\x1b\[[0-9]*m//g')"
  header="$(printf '%s\n' "$frame" | grep 'PROJECT')"
  row="$(printf '%s\n' "$frame" | grep 'detached')"

  prefix="${header%%STATE*}"
  header_pos="${#prefix}"
  prefix="${row%%detached*}"
  row_pos="${#prefix}"
  [[ "$header_pos" -eq "$row_pos" ]] || {
    echo "STATE column is misaligned (header $header_pos, row $row_pos):" >&2
    printf '%s\n%s\n' "$header" "$row" >&2
    return 1
  }
  [[ "$row" == *"feature/reranker-parity-and..."* ]] || {
    echo "long branch was not truncated: $row" >&2
    return 1
  }
}

test_connect_tui_runs_rd_tui_over_ssh() {
  local helper_dir="$TEST_ROOT/connect/helper"
  local ssh_log="$TEST_ROOT/connect/ssh.log"
  mkdir -p "$helper_dir"
  cp "$ROOT_DIR/connect.sh" "$helper_dir/connect.sh"
  cat > "$helper_dir/rd.env" <<'EOF'
VM_IP="192.0.2.10"
VM_USER="developer"
SSH_KEY="/tmp/example.key"
EOF

  SSH_LOG="$ssh_log" PATH="$TEST_ROOT/bin:$PATH" "$helper_dir/connect.sh" --tui
  grep -q -- '-t .*bash -lc rd-tui' "$ssh_log" || {
    echo "connect.sh --tui did not run rd-tui over ssh: $(cat "$ssh_log")" >&2
    return 1
  }
}

test_porcelain_lists_running_and_stopped_sessions
test_lists_running_and_stopped_and_quits_on_q
test_enter_attaches_to_the_selected_running_session
test_enter_restarts_a_stopped_session_before_attaching
test_s_stops_the_session_after_confirmation
test_n_declines_to_stop_when_not_confirmed
test_x_removes_a_stopped_worktree_and_keeps_the_branch
test_x_refuses_to_remove_a_running_session
test_new_session_wizard_starts_and_attaches
test_new_session_wizard_defaults_to_the_default_session
test_long_names_stay_aligned_and_long_branches_are_truncated
test_connect_tui_runs_rd_tui_over_ssh
echo "rd-tui tests passed"
