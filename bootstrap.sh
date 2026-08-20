#!/usr/bin/env bash
#
# Idempotent bootstrap for a remote Claude Code dev VM (Ubuntu).
# Run ON the VM, from the repo root:
#
#     ./bootstrap.sh
#
# Config is read from ./rd.env (GCP_PROJECT_ID, CLOUD_ML_REGION) if present,
# otherwise you are prompted. Safe to re-run.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# --- Load config -----------------------------------------------------------
if [[ -f "$SCRIPT_DIR/rd.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/rd.env"
fi
CLOUD_ML_REGION="${CLOUD_ML_REGION:-global}"
RD_PROVIDER="${RD_PROVIDER:-vertex}"
# USER is not exported by every non-login shell, and `set -u` turns a bare
# "$USER" into a hard abort — bootstrap-remote.sh runs this over `ssh host cmd`.
RUN_USER="${USER:-$(id -un)}"
# Only Vertex needs a value we cannot proceed without; the other providers are
# configured entirely from rd.env or by rd-auth.
if [[ "$RD_PROVIDER" == "vertex" && -z "${GCP_PROJECT_ID:-}" ]]; then
  read -rp "GCP (Vertex) project id: " GCP_PROJECT_ID
fi

# --- OS check --------------------------------------------------------------
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || warn "Not Ubuntu ($PRETTY_NAME); proceeding anyway."
export DEBIAN_FRONTEND=noninteractive

# --- Base packages ---------------------------------------------------------
log "Base packages"
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl gnupg git tmux python3 jq unzip \
  nodejs npm docker.io docker-compose-v2 unattended-upgrades

# --- Claude Code CLI -------------------------------------------------------
if ! command -v claude >/dev/null 2>&1; then
  log "Claude Code CLI (npm global)"
  sudo npm install -g @anthropic-ai/claude-code
fi

# The native binary ships as an optional per-platform package, and those
# occasionally lag a new release (seen with 2.1.237, whose linux-x64 package was
# unpublished). npm then reports success while every `claude` call fails, so
# check rather than trust the exit code.
if command -v claude >/dev/null 2>&1 && ! claude --version >/dev/null 2>&1; then
  warn "claude is installed but its native binary is missing (npm optional package unavailable)."
  warn "Pin the last release that has one, e.g.:  sudo npm install -g @anthropic-ai/claude-code@<version>"
  warn "List them with:  npm view @anthropic-ai/claude-code-linux-x64 versions"
fi

# --- Google Cloud CLI (signed apt repo, no piped installer) ----------------
if ! command -v gcloud >/dev/null 2>&1; then
  log "Google Cloud CLI"
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq google-cloud-cli
fi

# --- GitLab CLI (glab): MRs, pipelines, and git auth for cloning -----------
if ! command -v glab >/dev/null 2>&1; then
  log "GitLab CLI (glab)"
  # Arch-aware: OCI's Always Free shapes are Ampere (arm64), and an amd64-only
  # match would leave glab silently uninstalled there.
  GLAB_DEB_URL="$(curl -fsSL 'https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases' 2>/dev/null \
    | jq -r --arg suffix "linux_$(dpkg --print-architecture).deb" \
        '.[0].assets.links[]? | select(.name|endswith($suffix)) | .url' | head -1)"
  if [[ -n "${GLAB_DEB_URL:-}" ]] && curl -fsSL -o /tmp/glab.deb "$GLAB_DEB_URL"; then
    sudo dpkg -i /tmp/glab.deb || sudo apt-get install -y -f -qq
    rm -f /tmp/glab.deb
  else
    warn "Could not fetch glab .deb (is gitlab.com reachable?). Install manually: https://gitlab.com/gitlab-org/cli"
  fi
fi

# --- GitHub CLI (gh): PRs, checks, and git auth for cloning ----------------
# Unlike glab, GitHub publishes a signed apt repo, so this follows the gcloud
# pattern rather than fetching a release artifact.
if ! command -v gh >/dev/null 2>&1; then
  log "GitHub CLI (gh)"
  if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none; then
    sudo chmod 0644 /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq gh \
      || warn "Could not install gh — GitHub repos will not work until it is present."
  else
    warn "Could not fetch the GitHub CLI keyring (is cli.github.com reachable?). Install gh manually."
  fi
fi

# --- AWS CLI: only the Bedrock AWS SSO auth path needs it ------------------
# Not in the Ubuntu 24.04 archive at all (no candidate even with universe), so
# this uses AWS's own versioned zip — same fallback shape as glab's .deb.
if ! command -v aws >/dev/null 2>&1; then
  log "AWS CLI v2"
  AWS_TMP="$(mktemp -d)"
  if curl -fsSL -o "$AWS_TMP/awscliv2.zip" \
       "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" \
     && unzip -q "$AWS_TMP/awscliv2.zip" -d "$AWS_TMP"; then
    sudo "$AWS_TMP/aws/install" --update >/dev/null \
      || warn "AWS CLI installer failed — Bedrock via AWS SSO needs it."
  else
    warn "Could not fetch the AWS CLI — Bedrock via AWS SSO needs it; install it manually if you use that path."
  fi
  rm -rf "$AWS_TMP"
fi

# --- Docker group ----------------------------------------------------------
if ! id -nG "$RUN_USER" | tr ' ' '\n' | grep -qx docker; then
  sudo usermod -aG docker "$RUN_USER"
  warn "Added $RUN_USER to the docker group — re-login (or 'newgrp docker') to use docker without sudo."
fi

# --- Model provider configuration ------------------------------------------
# One file per provider, so a session picks exactly one of them up and the
# credentials never reach a command line or the tmux session environment.
log "Provider config in ~/.config/rd"
RD_CONFIG_DIR="$HOME/.config/rd"
PROVIDER_DIR="$RD_CONFIG_DIR/providers"
mkdir -p "$PROVIDER_DIR"
chmod 700 "$RD_CONFIG_DIR" "$PROVIDER_DIR"

write_provider() {
  local name="$1"
  shift
  local file="$PROVIDER_DIR/$name.env"
  (
    umask 077
    {
      printf '# Written by bootstrap.sh from rd.env — edit rd.env and re-run.\n'
      printf '%s\n' "$@"
    } > "$file"
  )
  chmod 600 "$file"
  echo "   provider '$name' configured"
}

if [[ -n "${GCP_PROJECT_ID:-}" ]]; then
  write_provider vertex \
    "export CLAUDE_CODE_USE_VERTEX=1" \
    "export ANTHROPIC_VERTEX_PROJECT_ID=$GCP_PROJECT_ID" \
    "export CLOUD_ML_REGION=$CLOUD_ML_REGION"
fi

if [[ -n "${AWS_REGION:-}" ]]; then
  bedrock_lines=(
    "export CLAUDE_CODE_USE_BEDROCK=1"
    "export AWS_REGION=$AWS_REGION"
  )
  [[ -n "${AWS_PROFILE:-}" ]] && bedrock_lines+=("export AWS_PROFILE=$AWS_PROFILE")
  [[ -n "${AWS_BEARER_TOKEN_BEDROCK:-}" ]] && \
    bedrock_lines+=("export AWS_BEARER_TOKEN_BEDROCK=$AWS_BEARER_TOKEN_BEDROCK")
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    bedrock_lines+=(
      "export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"
      "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY"
    )
    [[ -n "${AWS_SESSION_TOKEN:-}" ]] && \
      bedrock_lines+=("export AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN")
  fi
  # Without pins, 'opus'/'sonnet' resolve to Claude Code's built-in Bedrock
  # defaults, which may not be enabled in the account.
  [[ -n "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" ]] && \
    bedrock_lines+=("export ANTHROPIC_DEFAULT_OPUS_MODEL=$ANTHROPIC_DEFAULT_OPUS_MODEL")
  [[ -n "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ]] && \
    bedrock_lines+=("export ANTHROPIC_DEFAULT_SONNET_MODEL=$ANTHROPIC_DEFAULT_SONNET_MODEL")
  [[ -n "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" ]] && \
    bedrock_lines+=("export ANTHROPIC_DEFAULT_HAIKU_MODEL=$ANTHROPIC_DEFAULT_HAIKU_MODEL")
  write_provider bedrock "${bedrock_lines[@]}"
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  write_provider anthropic "export ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
elif [[ "$RD_PROVIDER" == "anthropic" && ! -f "$PROVIDER_DIR/anthropic.env" ]]; then
  # Subscription path: rd-auth appends CLAUDE_CODE_OAUTH_TOKEN here.
  write_provider anthropic "# rd-auth adds CLAUDE_CODE_OAUTH_TOKEN here."
fi

if [[ ! -r "$PROVIDER_DIR/$RD_PROVIDER.env" ]]; then
  warn "Default provider '$RD_PROVIDER' has no config — set its values in rd.env and re-run."
fi
printf '%s\n' "$RD_PROVIDER" > "$RD_CONFIG_DIR/provider"

# --- Provider switch in ~/.profile ------------------------------------------
log "Provider switch in ~/.profile"
MARK_BEGIN="# >>> remote-dev provider >>>"
MARK_END="# <<< remote-dev provider <<<"
# Remove the previous block AND the pre-multi-provider Vertex block, then
# re-append: idempotent, and it migrates an already-provisioned VM.
sed -i "/# >>> remote-dev vertex >>>/,/# <<< remote-dev vertex <<</d" "$HOME/.profile" 2>/dev/null || true
sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$HOME/.profile" 2>/dev/null || true
cat >> "$HOME/.profile" <<EOF
$MARK_BEGIN
export PATH="\$HOME/.local/bin:\$PATH"
# tmux starts panes as login shells, so this is where a session picks up its
# model provider. rd-start overrides it with: tmux new-session -e RD_PROVIDER=...
RD_PROVIDER="\${RD_PROVIDER:-\$(cat "\$HOME/.config/rd/provider" 2>/dev/null || echo vertex)}"
if [ -r "\$HOME/.config/rd/providers/\$RD_PROVIDER.env" ]; then
  . "\$HOME/.config/rd/providers/\$RD_PROVIDER.env"
fi
export RD_PROVIDER
$MARK_END
EOF

# --- Helper scripts --------------------------------------------------------
log "rd-* helpers -> ~/.local/bin"
mkdir -p "$HOME/.local/bin"
install -m 0755 "$SCRIPT_DIR"/bin/rd-* "$HOME/.local/bin/"

# --- Default Claude settings (do not clobber an existing one) ---------------
mkdir -p "$HOME/.claude"
if [[ ! -f "$HOME/.claude/settings.json" ]]; then
  log "Default ~/.claude/settings.json"
  cat > "$HOME/.claude/settings.json" <<'EOF'
{
  "model": "opus[1m]",
  "effortLevel": "high",
  "theme": "dark",
  "autoUpdatesChannel": "latest",
  "permissions": { "defaultMode": "default" }
}
EOF
fi

# --- Jira/Confluence via the Atlassian plugin (MCP) ------------------------
# Skills such as jira-to-mr use tools named mcp__plugin_atlassian_atlassian__*,
# so the *plugin* (not a bare `mcp add`) must be installed to match.
if command -v claude >/dev/null 2>&1; then
  if ! claude plugin list 2>/dev/null | grep -q "atlassian@claude-plugins-official"; then
    log "Atlassian (Jira/Confluence) plugin"
    claude plugin marketplace add anthropics/claude-plugins-official 2>/dev/null || true
    if claude plugin install atlassian@claude-plugins-official 2>&1 | tail -2; then
      claude plugin enable atlassian@claude-plugins-official 2>/dev/null || true
    else
      warn "Could not auto-install the atlassian plugin; install it in Claude with: /plugin"
    fi
  fi
fi

# --- tmux UX: mouse-wheel scrolling like a normal terminal -----------------
if [[ ! -f "$HOME/.tmux.conf" ]]; then
  log "tmux config (mouse scrolling)"
  install -m 0644 "$SCRIPT_DIR/tmux.conf" "$HOME/.tmux.conf"
fi
# Apply to any already-running tmux server without killing sessions.
tmux source-file "$HOME/.tmux.conf" 2>/dev/null || true

# --- Durability: linger + systemd user tmux service ------------------------
log "tmux systemd user service + linger"
mkdir -p "$HOME/.config/systemd/user"
install -m 0644 "$SCRIPT_DIR/systemd/tmux-claude.service" \
  "$HOME/.config/systemd/user/tmux-claude.service"
sudo loginctl enable-linger "$RUN_USER"
systemctl --user daemon-reload
systemctl --user enable --now tmux-claude.service

# --- Hardening -------------------------------------------------------------
log "SSH hardening + unattended-upgrades"
sudo install -m 0644 "$SCRIPT_DIR/hardening/60-hardening.conf" \
  /etc/ssh/sshd_config.d/60-hardening.conf
sudo install -m 0644 "$SCRIPT_DIR/hardening/20auto-upgrades" \
  /etc/apt/apt.conf.d/20auto-upgrades
if sudo sshd -t; then
  sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null || true
else
  warn "sshd config test failed — not reloading SSH."
fi

log "Done. Next steps (one-time authorizations open a URL — finish them in your laptop browser):"
cat <<EOF
  1) Re-login so the docker group and PATH apply:   exit; then ssh back in
  2) One-time authorizations (provider + forge):    rd-auth
                                                     rd-auth --provider bedrock   (a second provider)
  3) Jira/Confluence (Atlassian plugin OAuth):      run 'claude' once and trigger a Jira tool,
                                                     or in Claude: /plugin  (authorize when prompted)
  4) Interactive picker (start/attach/stop/remove): rd-tui
  5) Or start sessions by hand:                     rd-start <project>
                                                     rd-start <project> --session <name> [--type feature|bugfix]
                                                     rd-start <project> --provider bedrock
  6) Attach / detach:                               rd-attach <project> [--session <name>]
                                                     (detach: Ctrl-b then d)
  7) List / stop / remove:                          rd-list [--all] ; rd-stop <project> [--session <name>]
  8) VS Code automatic attach (per repo):           rd-vscode-init ~/projects/<project>
EOF
