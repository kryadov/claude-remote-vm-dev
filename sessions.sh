#!/usr/bin/env bash
# Laptop-side: list Claude Code sessions running on the VM (without attaching).
# Usage: ./sessions.sh      (Windows: bash ./sessions.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/rd.env" ]]; then
  echo "Create rd.env first (copy from rd.env.example)." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/rd.env"

exec ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" 'bash -lc rd-list'
