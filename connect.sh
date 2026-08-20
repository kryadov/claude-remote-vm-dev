#!/usr/bin/env bash
# Laptop-side: SSH into the VM using values from rd.env.
#
#   ./connect.sh
#   ./connect.sh --tui
#   ./connect.sh <project> [git-url|path] [rd-start options]
#   ./connect.sh backend --session login-timeout --type bugfix
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/rd.env" ]]; then
  echo "Create rd.env first (copy from rd.env.example)." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/rd.env"

if [[ "${1:-}" == "--tui" ]]; then
  [[ $# -eq 1 ]] || {
    echo "connect.sh: --tui takes no other arguments" >&2
    exit 2
  }
  exec ssh -t -i "$SSH_KEY" "$VM_USER@$VM_IP" 'bash -lc rd-tui'
fi

if [[ $# -gt 0 ]]; then
  PROJECT="$1"
  RD_SESSION="default"
  args=("$@")
  for ((index = 1; index < ${#args[@]}; index++)); do
    if [[ "${args[$index]}" == "--session" ]]; then
      ((index + 1 < ${#args[@]})) || {
        echo "connect.sh: --session requires a value" >&2
        exit 2
      }
      RD_SESSION="${args[$((index + 1))]}"
      break
    fi
  done

  printf -v start_command '%q ' rd-start "${args[@]}"
  if [[ "$RD_SESSION" == "default" ]]; then
    printf -v attach_command '%q ' rd-attach "$PROJECT"
  else
    printf -v attach_command '%q ' rd-attach "$PROJECT" --session "$RD_SESSION"
  fi
  remote_command="${start_command% } && ${attach_command% }"
  printf -v login_command 'bash -lc %q' "$remote_command"
  exec ssh -t -i "$SSH_KEY" "$VM_USER@$VM_IP" "$login_command"
fi

exec ssh -i "$SSH_KEY" "$VM_USER@$VM_IP"
