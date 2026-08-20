#!/usr/bin/env bash
#
# Laptop-side helper: clone this repo onto the VM (first time) and copy rd.env
# across, so you can then run ./bootstrap.sh on the VM. Reads rd.env.
#
#     ./bootstrap-remote.sh
#
# The first clone authenticates with GIT_CLONE_TOKEN (a read-only access token
# for the forge REPO_URL points at). The token is stripped from the stored git
# remote afterwards; from then on the credentials rd-auth installed handle git.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/rd.env" ]]; then
  echo "Create rd.env first (copy from rd.env.example)." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/rd.env"
: "${VM_IP:?set VM_IP in rd.env}" "${VM_USER:?}" "${SSH_KEY:?}" \
  "${REPO_URL:?set REPO_URL in rd.env}"

REPO_DIR="$(basename "$REPO_URL" .git)"

# Authenticated URL for the first clone, if a token is provided. GitLab wants
# oauth2:<token>, GitHub wants x-access-token:<token>; either way the token is
# stripped from the stored remote right after the clone.
clone_url="$REPO_URL"
if [[ -n "${GIT_CLONE_TOKEN:-}" ]]; then
  repo_host="${REPO_URL#https://}"
  repo_host="${repo_host%%/*}"
  forge="${FORGE:-}"
  if [[ -z "$forge" ]]; then
    case "$repo_host" in
      *github*) forge="github" ;;
      *) forge="gitlab" ;;
    esac
  fi
  case "$forge" in
    github) clone_user="x-access-token" ;;
    gitlab) clone_user="oauth2" ;;
    *)
      echo "Unknown FORGE '$forge' in rd.env (expected gitlab or github)." >&2
      exit 1
      ;;
  esac
  clone_url="https://${clone_user}:${GIT_CLONE_TOKEN}@${REPO_URL#https://}"
fi

echo "==> Cloning/updating $REPO_DIR on $VM_USER@$VM_IP"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$VM_USER@$VM_IP" \
  "REPO_DIR='$REPO_DIR' CLONE_URL='$clone_url' CLEAN_URL='$REPO_URL' bash -s" <<'REMOTE'
set -euo pipefail
if [ -d "$HOME/$REPO_DIR/.git" ]; then
  git -C "$HOME/$REPO_DIR" pull --ff-only || true
else
  git clone "$CLONE_URL" "$HOME/$REPO_DIR"
  # Strip any embedded token from the stored remote URL.
  git -C "$HOME/$REPO_DIR" remote set-url origin "$CLEAN_URL"
fi
REMOTE

echo "==> Copying rd.env to the VM (bootstrap reads the provider and forge values from it)"
scp -i "$SSH_KEY" "$SCRIPT_DIR/rd.env" "$VM_USER@$VM_IP:~/$REPO_DIR/rd.env"

echo "==> Running bootstrap.sh on the VM"
ssh -i "$SSH_KEY" "$VM_USER@$VM_IP" "cd ~/$REPO_DIR && ./bootstrap.sh"

cat <<EOF

VM provisioned. Two steps left:
  1) ./connect.sh                # (Windows: bash ./connect.sh, or .\\connect.ps1)
  2) rd-auth                     # one-time: model provider + forge + git author
Then:  rd-start <project>
EOF
