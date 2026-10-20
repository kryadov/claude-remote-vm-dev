#!/usr/bin/env bash
# Sync Claude Code per-project memory between the laptop and the VM.
#
# Claude stores memory under ~/.claude/projects/<ENCODED-ABSOLUTE-PATH>/memory/,
# where the folder name is the project's absolute path with `/ \ :` replaced by
# `-`. The laptop path (C:\Users\...) and the VM path (/home/<user>/projects/...)
# differ, so this maps between them and copies the memory/ folder.
#
#   ./sync-memory.sh push <project-name> [vm-project-path]   # laptop -> VM (default)
#   ./sync-memory.sh pull <project-name> [vm-project-path]   # VM -> laptop
#
# <project-name> is the project folder's basename (e.g. project1).
# vm-project-path defaults to /home/<VM_USER>/projects/<project-name>.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/rd.env" ]]; then
  echo "Create rd.env first (copy from rd.env.example)." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/rd.env"

DIR="push"
case "${1:-}" in push|pull) DIR="$1"; shift;; esac
NAME="${1:?usage: sync-memory.sh [push|pull] <project-name> [vm-project-path]}"
VM_PROJ="${2:-/home/$VM_USER/projects/$NAME}"

enc() { printf '%s' "$1" | sed -E 's#[:/\\]#-#g'; }

# Locate the laptop project's memory dir by matching the encoded folder name.
shopt -s nullglob
cands=( "$HOME/.claude/projects/"*"-$NAME" )
shopt -u nullglob
if (( ${#cands[@]} == 0 )); then
  echo "No local project dir matching *-$NAME under ~/.claude/projects" >&2; exit 1
fi
if (( ${#cands[@]} > 1 )); then
  printf 'Ambiguous — multiple matches:\n%s\n' "${cands[@]}" >&2; exit 1
fi
LMEM="${cands[0]}/memory"
VMEM="/home/$VM_USER/.claude/projects/$(enc "$VM_PROJ")/memory"
REMOTE="$VM_USER@$VM_IP"

if [[ "$DIR" == push ]]; then
  [[ -d "$LMEM" ]] || { echo "No local memory at $LMEM" >&2; exit 1; }
  tar -C "$LMEM" -cf - . | ssh -i "$SSH_KEY" "$REMOTE" "mkdir -p '$VMEM' && tar -C '$VMEM' -xf -"
  echo "Pushed memory:  $LMEM  ->  $REMOTE:$VMEM"
else
  mkdir -p "$LMEM"
  ssh -i "$SSH_KEY" "$REMOTE" "tar -C '$VMEM' -cf - ." | tar -C "$LMEM" -xf -
  echo "Pulled memory:  $REMOTE:$VMEM  ->  $LMEM"
fi
