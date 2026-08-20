# GitHub + Multi-Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a remote-dev VM talk to GitHub as well as GitLab, and run Claude Code sessions against Amazon Bedrock or the direct Anthropic API as well as GCP Vertex, with a per-VM default provider and a per-session override.

**Architecture:** Provider configuration lives in per-provider files under `~/.config/rd/providers/` (mode 0600); `~/.profile` sources exactly one of them based on `RD_PROVIDER`, which defaults to the contents of `~/.config/rd/provider`. `rd-start` overrides it by passing the single variable `RD_PROVIDER` across the tmux boundary with `tmux new-session -e`, so secrets never reach `ps` output or the tmux session environment. Forges get no wrapper: both `gh` and `glab` are installed, `rd-auth` logs in to the right one and installs a **host-scoped** git credential helper, and day-to-day the CLIs resolve the forge from the repository's own remote.

**Tech Stack:** Bash (`set -euo pipefail`), tmux user options, git credential helpers, apt (signed repos where available), stub-driven bash tests.

**Spec:** `docs/superpowers/specs/2026-08-15-github-and-multi-provider-design.md`

## Global Constraints

- Every script is `bash`, starts with `set -euo pipefail`, and stays **idempotent** — `bootstrap.sh` is re-run on live VMs.
- Guard every edit to a user file with marker comments (`# >>> remote-dev provider >>>` / `# <<< remote-dev provider <<<`).
- **Nothing environment-specific in tracked files** — no real hosts, project ids, emails, keys. Values live in `rd.env` (gitignored).
- **No secret in a process argument list, a tracked file, or the tmux session environment.** Provider files are mode 0600; only the provider *name* crosses the tmux boundary.
- Provider names are exactly `vertex`, `bedrock`, `anthropic`.
- Session identity is unchanged: `claude-<project>` for `default`, `claude-<project>--<session>` otherwise; metadata lives in tmux user options (`@rd_project`, `@rd_session`, `@rd_worktree`, and now `@rd_provider`).
- `rd-tui` owns no logic — it renders and shells out. New rules go in the command that owns them.
- Tests stub the outside world and run against a temp `HOME`; they must never touch a real VM, a real tmux, or a real cloud.
- **This checkout is not a git repository on the current machine.** Where a step says "commit", run the full test suite instead and treat green as the checkpoint. Restore the commits when the work lands in a real checkout.

**Full test suite** (the checkpoint command, run from the repo root):

```bash
bash -n bootstrap.sh bootstrap-remote.sh connect.sh sessions.sh sync-memory.sh bin/rd-* \
  && bash tests/test-rd-auth.sh \
  && bash tests/test-rd-sessions.sh \
  && bash tests/test-rd-tui.sh \
  && bash tests/test-rd-provider.sh
```

On Windows this runs in a Linux container (Rancher Desktop / Docker):

```bash
docker run --rm -v "$(pwd -W)":/repo -w /repo alpine:3.20 sh -c \
  'apk add --no-cache bash git python3 >/dev/null && <suite command>'
```

---

### Task 1: `rd-start --provider`

Teaches `rd-start` to resolve a provider, hand it to tmux, and record it. The tmux stub learns to record `-e` pairs, which every later provider test depends on.

**Files:**
- Modify: `bin/rd-start` (usage/arg loop ~lines 5-62; session creation ~lines 161-191)
- Modify: `tests/stubs/tmux` (`new-session` branch)
- Create: `tests/test-rd-provider.sh`

**Interfaces:**
- Consumes: `tests/lib.sh` → `rd_test_install_stubs <dir>`, `rd_test_new_repo <path>`; stub env vars `TMUX_STATE`, `TMUX_LOG`.
- Produces: `rd-start [--provider <name>]`; tmux user option `@rd_provider`; config paths `~/.config/rd/provider` (default name) and `~/.config/rd/providers/<name>.env` (must exist for `<name>` to be valid).

- [ ] **Step 1: Teach the tmux stub to record `-e` pairs**

In `tests/stubs/tmux`, the `new-session` branch currently drops unknown flags. Record `-e` into the state line so tests can assert on it:

```bash
  new-session)
    name=""
    path=""
    envs=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -d) shift ;;
        -s) name="$2"; shift 2 ;;
        -c) path="$2"; shift 2 ;;
        -e) envs="${envs:+$envs }$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\t%s\tdetached\t%s\n' "$name" "$(date +%s)" "$path" >> "$TMUX_STATE"
    printf '%s' "$envs" > "$TMUX_STATE.$name.env"
    ;;
```

- [ ] **Step 2: Write the failing tests**

Create `tests/test-rd-provider.sh`:

```bash
#!/usr/bin/env bash
# rd-start provider resolution: default, override, validation, mismatch.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
  local home="$1"
  shift
  HOME="$home" PATH="$BIN:$PATH" \
    TMUX_STATE="$home/tmux-state" TMUX_LOG="$home/tmux-log" \
    "$ROOT_DIR/bin/rd-start" "$@"
}

session_env() { cat "$1/tmux-state.claude-demo.env" 2>/dev/null || true; }
session_option() { cat "$1/tmux-state.claude-demo.rd_provider" 2>/dev/null || true; }

test_default_provider_is_recorded_without_env_injection() {
  local home
  home="$(new_home default)"
  run_rd "$home" demo >/dev/null
  [[ "$(session_option "$home")" == "vertex" ]]
  # No --provider means the login shell reads the default file itself.
  [[ -z "$(session_env "$home")" ]]
}

test_provider_override_crosses_the_tmux_boundary() {
  local home
  home="$(new_home override)"
  run_rd "$home" demo --provider bedrock >/dev/null
  [[ "$(session_env "$home")" == "RD_PROVIDER=bedrock" ]]
  [[ "$(session_option "$home")" == "bedrock" ]]
}

test_rejects_unconfigured_provider() {
  local home output
  home="$(new_home unknown)"
  if output="$(run_rd "$home" demo --provider nope 2>&1)"; then
    echo "rd-start accepted an unconfigured provider" >&2
    return 1
  fi
  [[ "$output" == *"nope"* ]]
  [[ "$output" == *"vertex"* && "$output" == *"bedrock"* ]]
}

test_rejects_provider_change_on_running_session() {
  local home output
  home="$(new_home mismatch)"
  run_rd "$home" demo --provider bedrock >/dev/null
  if output="$(run_rd "$home" demo --provider vertex 2>&1)"; then
    echo "rd-start accepted a provider change on a running session" >&2
    return 1
  fi
  [[ "$output" == *"bedrock"* && "$output" == *"vertex"* ]]
  [[ "$output" == *"rd-stop"* ]]
}

test_default_provider_is_recorded_without_env_injection
test_provider_override_crosses_the_tmux_boundary
test_rejects_unconfigured_provider
test_rejects_provider_change_on_running_session
echo "rd-start provider tests passed"
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/test-rd-provider.sh`
Expected: FAIL — `rd-start` rejects the unknown flag `--provider` with its usage message.

- [ ] **Step 4: Add provider resolution to `rd-start`**

Extend the usage line and the argument loop:

```bash
usage() {
  echo "usage: rd-start <project> [git-url|path] [--session <name>] [--type feature|bugfix] [--base <ref>] [--branch feature/<name>|bugfix/<name>] [--provider <name>]" >&2
  exit 2
}
```

```bash
PROVIDER=""
PROVIDER_EXPLICIT=0
```

```bash
    --provider)
      [[ $# -ge 2 ]] || usage
      PROVIDER="$2"
      PROVIDER_EXPLICIT=1
      shift 2
      ;;
```

After the session-name validation, resolve and validate:

```bash
RD_CONFIG_DIR="${RD_CONFIG_DIR:-$HOME/.config/rd}"
PROVIDER_DIR="$RD_CONFIG_DIR/providers"

configured_providers() {
  local file
  shopt -s nullglob
  for file in "$PROVIDER_DIR"/*.env; do
    basename "$file" .env
  done
  shopt -u nullglob
}

if [[ -z "$PROVIDER" ]]; then
  PROVIDER="$(cat "$RD_CONFIG_DIR/provider" 2>/dev/null || true)"
  PROVIDER="${PROVIDER%%$'\n'*}"
  PROVIDER="${PROVIDER:-vertex}"
fi

if [[ ! -r "$PROVIDER_DIR/$PROVIDER.env" ]]; then
  available="$(configured_providers | paste -sd' ' -)"
  echo "rd-start: provider '$PROVIDER' is not configured in $PROVIDER_DIR" >&2
  echo "          configured: ${available:-<none — run bootstrap.sh, then rd-auth>}" >&2
  exit 2
fi
```

- [ ] **Step 5: Pass the provider to tmux and record it**

In the reuse branch (`TMUX_EXISTS -eq 1`), before the existing `set-option` calls:

```bash
  existing_provider="$(tmux_option @rd_provider)"
  if [[ "$PROVIDER_EXPLICIT" -eq 1 && -n "$existing_provider" && "$existing_provider" != "$PROVIDER" ]]; then
    echo "rd-start: session '$TMUX_SESSION' already runs on provider '$existing_provider', not '$PROVIDER'." >&2
    echo "          A pane's provider is fixed when it starts; stop it first: rd-stop $PROJECT" >&2
    exit 1
  fi
  tmux set-option -t "=$TMUX_SESSION:" @rd_provider "${existing_provider:-$PROVIDER}"
```

In the creation branch, inject only when overridden, then record:

```bash
if [[ "$PROVIDER_EXPLICIT" -eq 1 ]]; then
  tmux new-session -d -s "$TMUX_SESSION" -c "$WORKDIR" -e RD_PROVIDER="$PROVIDER"
else
  tmux new-session -d -s "$TMUX_SESSION" -c "$WORKDIR"
fi
tmux set-option -t "=$TMUX_SESSION:" @rd_provider "$PROVIDER"
```

Add the provider to the final message: `echo "Started '$TMUX_SESSION' in $WORKDIR (provider: $PROVIDER)."`

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test-rd-provider.sh`
Expected: PASS — `rd-start provider tests passed`

- [ ] **Step 7: Checkpoint**

Run the full test suite. Expected: all four suites pass.

---

### Task 2: Provider column in `rd-list` and `rd-tui`

**Files:**
- Modify: `bin/rd-list` (format string line 27; row assembly ~lines 37-66; output ~lines 75-90)
- Modify: `bin/rd-tui` (`load_sessions` ~lines 103-123; `render_list` ~lines 171-202)
- Modify: `tests/stubs/tmux` (`list-sessions` branch)
- Modify: `tests/test-rd-provider.sh`

**Interfaces:**
- Consumes: `@rd_provider` from Task 1.
- Produces: `rd-list --porcelain` columns become `state, project, session, branch, dir, created, provider` — provider **appended last** so existing readers are unaffected.

- [ ] **Step 1: Teach the tmux stub to report `@rd_provider`**

In the `list-sessions` branch, emit a 7th field when the format asks for it:

```bash
      if [[ "$format" == *"@rd_worktree"* ]]; then
        worktree="$(cat "$TMUX_STATE.$name.rd_worktree" 2>/dev/null || true)"
        printf '%s\t%s\t%s\t%s\n' "$name" "$project" "$session" "$worktree"
      elif [[ "$format" == *"@rd_provider"* ]]; then
        provider="$(cat "$TMUX_STATE.$name.rd_provider" 2>/dev/null || true)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$name" "$project" "$session" "$created" "$state" "$path" "$provider"
      else
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$name" "$project" "$session" "$created" "$state" "$path"
      fi
```

- [ ] **Step 2: Write the failing test**

Append to `tests/test-rd-provider.sh`, before the runner lines:

```bash
test_rd_list_reports_the_provider() {
  local home porcelain
  home="$(new_home listing)"
  run_rd "$home" demo --provider bedrock >/dev/null
  porcelain="$(HOME="$home" PATH="$BIN:$PATH" \
    TMUX_STATE="$home/tmux-state" TMUX_LOG="$home/tmux-log" \
    "$ROOT_DIR/bin/rd-list" --porcelain)"
  # state, project, session, branch, dir, created, provider
  [[ "$(cut -f7 <<< "$porcelain")" == "bedrock" ]]
}
```

and add `test_rd_list_reports_the_provider` to the runner list.

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/test-rd-provider.sh`
Expected: FAIL — column 7 is empty; `rd-list` does not ask tmux for `@rd_provider`.

- [ ] **Step 4: Add the column to `rd-list`**

Extend the format string:

```bash
fmt=$'#{session_name}\t#{@rd_project}\t#{@rd_session}\t#{session_created}\t#{?session_attached,attached,detached}\t#{pane_current_path}\t#{@rd_provider}'
```

Read the extra field and append it to each row:

```bash
while IFS=$'\t' read -r name project rd_session created state path provider; do
```

```bash
  rows+=("$state"$'\t'"$project"$'\t'"$rd_session"$'\t'"$(branch_of "$path")"$'\t'"$path"$'\t'"$created"$'\t'"${provider:-}")
```

Stopped sessions have no tmux session to ask, so their provider is empty:

```bash
    rows+=("stopped"$'\t'"$project"$'\t'"$session"$'\t'"$(branch_of "$dir")"$'\t'"$dir"$'\t'$'\t')
```

Sort and print with the extra field:

```bash
printf '%-18s %-18s %-9s %-17s %-10s %-24s %s\n' PROJECT SESSION STATE CREATED PROVIDER BRANCH DIR
while IFS=$'\t' read -r state project session branch dir created provider; do
  [[ -n "$state" ]] || continue
  if [[ -n "$created" ]]; then
    when="$(date -d "@$created" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$created")"
  else
    when="-"
  fi
  printf '%-18s %-18s %-9s %-17s %-10s %-24s %s\n' \
    "$project" "$session" "$state" "$when" "${provider:--}" "${branch:--}" "$dir"
done <<< "$sorted"
```

Update the header comment so the porcelain contract stays documented:

```bash
# Porcelain columns: state, project, session, branch, dir, created (epoch), provider.
# 'created' and 'provider' are empty for stopped sessions — there is no tmux
# session to ask.
```

- [ ] **Step 5: Render it in `rd-tui`**

Add a `PROVIDERS` array beside the others, populate it in `load_sessions`:

```bash
  while IFS=$'\t' read -r state project session branch dir created provider; do
    [[ -n "$state" ]] || continue
    : "${created:-}"
    STATES+=("$state")
    PROJECTS+=("$project")
    SESSIONS+=("$session")
    BRANCHES+=("${branch:--}")
    DIRS+=("$dir")
    PROVIDERS+=("${provider:--}")
  done <<< "$porcelain"
```

(reset `PROVIDERS=()` with the other arrays at the top of `load_sessions`, and declare `PROVIDERS=()` next to `DIRS=()` at the top of the data section)

and render it between STATE and BRANCH:

```bash
    pw="$(column_width PROJECT 24 "${PROJECTS[@]}")"
    sw="$(column_width SESSION 20 "${SESSIONS[@]}")"
    vw="$(column_width PROVIDER 12 "${PROVIDERS[@]}")"
    bw="$(column_width BRANCH 30 "${BRANCHES[@]}")"
    printf "  %-${pw}s %-${sw}s %-9s %-${vw}s %-${bw}s %s\n" PROJECT SESSION STATE PROVIDER BRANCH DIR
    for index in "${!STATES[@]}"; do
      printf -v line " %-${pw}s %-${sw}s %-9s %-${vw}s %-${bw}s %s" \
        "$(fit "${PROJECTS[$index]}" "$pw")" "$(fit "${SESSIONS[$index]}" "$sw")" \
        "${STATES[$index]}" "$(fit "${PROVIDERS[$index]}" "$vw")" \
        "$(fit "${BRANCHES[$index]}" "$bw")" "${DIRS[$index]}"
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test-rd-provider.sh && bash tests/test-rd-tui.sh`
Expected: PASS both. If a TUI test asserts on the old header, update the assertion — the column is intended.

- [ ] **Step 7: Checkpoint**

Run the full test suite.

---

### Task 3: Provider-aware `rd-auth`

**Files:**
- Modify: `bin/rd-auth` (whole file — the three-step script becomes provider- and forge-aware; the forge half is Task 4)
- Modify: `tests/test-rd-auth.sh`

**Interfaces:**
- Consumes: `~/.config/rd/provider`, `~/.config/rd/providers/<name>.env` from Task 1.
- Produces: `rd-auth [--provider <name>] [--forge github|gitlab] [<forge-host>]`; writes `CLAUDE_CODE_OAUTH_TOKEN` into `providers/anthropic.env` at mode 0600.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-rd-auth.sh`. First extend the stub set (beside the existing `gcloud`/`glab`/`git` stubs) with `aws` and `claude`:

```bash
cat > "$TEST_ROOT/bin/aws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/aws-log"
[[ "$1 $2" == "sso login" ]] && exit 0
exit 1
EOF

cat > "$TEST_ROOT/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/claude-log"
[[ "$1" == "setup-token" ]] || exit 1
echo "sk-ant-oat01-EXAMPLE"
EOF

chmod +x "$TEST_ROOT/bin/aws" "$TEST_ROOT/bin/claude"
```

Then the tests:

```bash
# Builds a HOME whose rd.env is valid and whose default provider is $1.
auth_home() {
  local home="$TEST_ROOT/$1/home" provider="$2"
  mkdir -p "$home/remote-dev" "$home/.config/rd/providers"
  cat > "$home/remote-dev/rd.env" <<'EOF'
REPO_URL="https://gitlab.example.com/example/remote-dev.git"
GIT_USER_NAME="Example Developer"
GIT_USER_EMAIL="developer@example.com"
EOF
  printf '%s\n' "$provider" > "$home/.config/rd/provider"
  printf '%s' "$home"
}

test_bedrock_sso_login() {
  local home
  home="$(auth_home bedrock bedrock)"
  cat > "$home/.config/rd/providers/bedrock.env" <<'EOF'
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION=eu-central-1
export AWS_PROFILE=dev-sso
EOF
  HOME="$home" PATH="$TEST_ROOT/bin:$PATH" "$ROOT_DIR/bin/rd-auth" >/dev/null
  grep -q -- "sso login --profile dev-sso" "$home/aws-log"
  # Vertex ADC must not run when Bedrock is the provider.
  [[ ! -f "$home/gcloud-log" ]] || ! grep -q "application-default" "$home/gcloud-log"
}

test_anthropic_subscription_writes_oauth_token() {
  local home mode
  home="$(auth_home anthropic anthropic)"
  printf '# anthropic\n' > "$home/.config/rd/providers/anthropic.env"
  HOME="$home" PATH="$TEST_ROOT/bin:$PATH" "$ROOT_DIR/bin/rd-auth" </dev/null >/dev/null
  grep -q "setup-token" "$home/claude-log"
  grep -q 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-EXAMPLE' "$home/.config/rd/providers/anthropic.env"
  mode="$(stat -c '%a' "$home/.config/rd/providers/anthropic.env")"
  [[ "$mode" == "600" ]]
}

test_anthropic_api_key_needs_no_login() {
  local home
  home="$(auth_home apikey anthropic)"
  printf 'export ANTHROPIC_API_KEY=sk-ant-EXAMPLE\n' > "$home/.config/rd/providers/anthropic.env"
  HOME="$home" PATH="$TEST_ROOT/bin:$PATH" "$ROOT_DIR/bin/rd-auth" >/dev/null
  [[ ! -f "$home/claude-log" ]]
}
```

Register the three tests in the runner list at the bottom.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-rd-auth.sh`
Expected: FAIL — `rd-auth` runs `gcloud` unconditionally and knows nothing about `aws`, `claude setup-token`, or provider files.

- [ ] **Step 3: Restructure `rd-auth` around the resolved provider**

Keep `read_env_value` and the `rd.env` discovery as they are. Add argument parsing and provider resolution before the auth steps:

```bash
PROVIDER=""
FORGE=""
FORGE_HOST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) [[ $# -ge 2 ]] || usage; PROVIDER="$2"; shift 2 ;;
    --forge)    [[ $# -ge 2 ]] || usage; FORGE="$2"; shift 2 ;;
    --*)        usage ;;
    *)          [[ -z "$FORGE_HOST" ]] || usage; FORGE_HOST="$1"; shift ;;
  esac
done

RD_CONFIG_DIR="${RD_CONFIG_DIR:-$HOME/.config/rd}"
PROVIDER_DIR="$RD_CONFIG_DIR/providers"
if [[ -z "$PROVIDER" ]]; then
  PROVIDER="$(cat "$RD_CONFIG_DIR/provider" 2>/dev/null || true)"
  PROVIDER="${PROVIDER%%$'\n'*}"
  PROVIDER="${PROVIDER:-vertex}"
fi
PROVIDER_FILE="$PROVIDER_DIR/$PROVIDER.env"
```

with a `usage()` matching the new signature. Replace the hard-coded `== 1/3 Vertex ==` step with a dispatch:

```bash
echo "== 1/3  Model provider: $PROVIDER =="
provider_has() { [[ -r "$PROVIDER_FILE" ]] && grep -qE "^[[:space:]]*(export[[:space:]]+)?$1=" "$PROVIDER_FILE"; }
provider_value() {
  local value
  value="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$PROVIDER_FILE" | head -1 | cut -d= -f2-)"
  value="${value%$'\r'}"
  case "$value" in \"*\"|\'*\') value="${value:1:${#value}-2}" ;; esac
  printf '%s' "$value"
}

case "$PROVIDER" in
  vertex)
    if gcloud auth application-default print-access-token >/dev/null 2>&1; then
      echo "   Vertex ADC already authenticated ✓"
    else
      gcloud auth application-default login --no-launch-browser
    fi
    ;;
  bedrock)
    if provider_has AWS_PROFILE; then
      profile="$(provider_value AWS_PROFILE)"
      if aws sts get-caller-identity --profile "$profile" >/dev/null 2>&1; then
        echo "   AWS profile '$profile' already valid ✓"
      else
        aws sso login --profile "$profile"
      fi
    elif provider_has AWS_BEARER_TOKEN_BEDROCK || provider_has AWS_ACCESS_KEY_ID; then
      echo "   Bedrock uses a static credential from $PROVIDER_FILE — nothing to log in ✓"
    else
      echo "rd-auth: $PROVIDER_FILE has no AWS_PROFILE, AWS_BEARER_TOKEN_BEDROCK or AWS_ACCESS_KEY_ID." >&2
      echo "         Set one in rd.env and re-run bootstrap.sh." >&2
      exit 1
    fi
    ;;
  anthropic)
    if provider_has ANTHROPIC_API_KEY || provider_has CLAUDE_CODE_OAUTH_TOKEN; then
      echo "   Anthropic credential already present in $PROVIDER_FILE ✓"
    else
      echo "   Subscription login — authorize the URL, then paste the token back here."
      token="$(claude setup-token | tail -1 | tr -d '[:space:]')"
      [[ -n "$token" ]] || { echo "rd-auth: claude setup-token returned nothing" >&2; exit 1; }
      umask 077
      printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$token" >> "$PROVIDER_FILE"
      chmod 600 "$PROVIDER_FILE"
      echo "   OAuth token stored in $PROVIDER_FILE (0600) ✓"
    fi
    ;;
  *)
    echo "rd-auth: unknown provider '$PROVIDER'" >&2
    exit 2
    ;;
esac
```

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test-rd-auth.sh`
Expected: PASS — `rd-auth tests passed`

- [ ] **Step 5: Checkpoint**

Run the full test suite.

---

### Task 4: Forge resolution and host-scoped credential helper

**Files:**
- Modify: `bin/rd-auth` (step 2 of 3)
- Modify: `tests/test-rd-auth.sh`

**Interfaces:**
- Consumes: `FORGE`/`FORGE_HOST` parsed in Task 3; `REPO_URL` and the new optional `FORGE` key in `rd.env`.
- Produces: host-scoped `credential.https://<host>.helper`; `gh auth login --hostname <host>` + `gh auth setup-git --hostname <host>` for GitHub.

- [ ] **Step 1: Write the failing tests**

Extend the `git` stub in `tests/test-rd-auth.sh` so scoped keys round-trip (the current stub maps `.` to `-`, which already yields a unique filename per key — keep it) and add a `gh` stub:

```bash
cat > "$TEST_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/gh-log"
[[ "$1 $2" == "auth status" ]] && exit 1
exit 0
EOF
chmod +x "$TEST_ROOT/bin/gh"
```

Tests:

```bash
test_github_remote_uses_gh() {
  local home
  home="$(auth_home github vertex)"
  printf 'export CLAUDE_CODE_USE_VERTEX=1\n' > "$home/.config/rd/providers/vertex.env"
  cat > "$home/remote-dev/rd.env" <<'EOF'
REPO_URL="https://github.example.com/example/remote-dev.git"
FORGE="github"
GIT_USER_NAME="Example Developer"
GIT_USER_EMAIL="developer@example.com"
EOF
  HOME="$home" PATH="$TEST_ROOT/bin:$PATH" "$ROOT_DIR/bin/rd-auth" >/dev/null
  grep -q -- "auth login --hostname github.example.com" "$home/gh-log"
  grep -q -- "auth setup-git --hostname github.example.com" "$home/gh-log"
  [[ ! -f "$home/glab-log" ]]
}

test_gitlab_credential_helper_is_host_scoped() {
  local home
  home="$(auth_home scoped vertex)"
  printf 'export CLAUDE_CODE_USE_VERTEX=1\n' > "$home/.config/rd/providers/vertex.env"
  HOME="$home" PATH="$TEST_ROOT/bin:$PATH" "$ROOT_DIR/bin/rd-auth" >/dev/null
  # credential.https://gitlab.example.com.helper -> the stub's flattened filename
  [[ -f "$home/.credential-https://gitlab-example-com-helper" ]]
  [[ ! -f "$home/.credential-helper" ]]
}

test_migrates_legacy_global_credential_helper() {
  local home
  home="$(auth_home legacy vertex)"
  printf 'export CLAUDE_CODE_USE_VERTEX=1\n' > "$home/.config/rd/providers/vertex.env"
  printf '%s' '!glab auth git-credential' > "$home/.credential-helper"
  HOME="$home" PATH="$TEST_ROOT/bin:$PATH" "$ROOT_DIR/bin/rd-auth" >/dev/null
  [[ ! -f "$home/.credential-helper" ]]
  [[ -f "$home/.credential-https://gitlab-example-com-helper" ]]
}
```

The `git` stub needs `--unset` support for the migration test:

```bash
if [[ "$1 $2 $3" == "config --global --unset" ]]; then
  rm -f "$HOME/.${4//./-}"
  exit 0
fi
```

Register the three tests in the runner list.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/test-rd-auth.sh`
Expected: FAIL — `rd-auth` always calls `glab` and always sets a global helper.

- [ ] **Step 3: Implement forge resolution and the scoped helper**

Replace step 2 of `rd-auth`:

```bash
echo "== 2/3  Forge login + Git author =="

if [[ -z "$FORGE_HOST" && -n "$ENV_FILE" ]]; then
  url="$(read_env_value REPO_URL "$ENV_FILE")"
  FORGE_HOST="$(echo "$url" | sed -E 's#https?://([^/]+)/.*#\1#')"
fi
if [[ -z "$FORGE_HOST" ]]; then
  read -rp "   Forge host (e.g. gitlab.example.com): " FORGE_HOST
fi

if [[ -z "$FORGE" && -n "$ENV_FILE" ]]; then
  FORGE="$(read_env_value FORGE "$ENV_FILE")"
fi
if [[ -z "$FORGE" ]]; then
  case "$FORGE_HOST" in
    github.com) FORGE="github" ;;
    gitlab.com) FORGE="gitlab" ;;
    *)
      read -rp "   Is $FORGE_HOST GitLab or GitHub? [gitlab/github] " FORGE
      ;;
  esac
fi

# A global glab helper answers for GitHub hosts too and breaks every GitHub
# push — migrate any legacy one to a host-scoped helper.
legacy="$(git config --global --get credential.helper 2>/dev/null || true)"
if [[ "$legacy" == '!glab auth git-credential' ]]; then
  git config --global --unset credential.helper
  echo "   migrated the legacy global glab credential helper ✓"
fi

case "$FORGE" in
  gitlab)
    if glab auth status 2>&1 | grep -q "$FORGE_HOST"; then
      echo "   already logged in to $FORGE_HOST ✓"
    else
      echo "   Create a token (scope: api), then choose 'Token' and paste it:"
      echo "   https://$FORGE_HOST/-/user_settings/personal_access_tokens?name=remote-dev-vm&scopes=api"
      glab auth login --hostname "$FORGE_HOST"
    fi
    git config --global "credential.https://$FORGE_HOST.helper" '!glab auth git-credential'
    ;;
  github)
    if gh auth status --hostname "$FORGE_HOST" >/dev/null 2>&1; then
      echo "   already logged in to $FORGE_HOST ✓"
    else
      echo "   Create a token (scopes: repo, read:org), then choose 'Token' and paste it:"
      echo "   https://$FORGE_HOST/settings/tokens/new?scopes=repo,read:org&description=remote-dev-vm"
      gh auth login --hostname "$FORGE_HOST"
    fi
    gh auth setup-git --hostname "$FORGE_HOST"
    ;;
  *)
    echo "rd-auth: unknown forge '$FORGE' (expected gitlab or github)" >&2
    exit 2
    ;;
esac
echo "   git credentials scoped to https://$FORGE_HOST ✓"
```

Keep the existing `git config --global user.name/user.email` lines and the Jira step below it.

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/test-rd-auth.sh`
Expected: PASS

- [ ] **Step 5: Checkpoint**

Run the full test suite.

---

### Task 5: `bootstrap.sh` — provider files, profile switch, `gh` and `awscli`

**Files:**
- Modify: `bootstrap.sh` (config load ~lines 17-25; CLI installs ~lines 56-67; Vertex env block ~lines 75-88; final next-steps text)

**Interfaces:**
- Consumes: `rd.env` keys from Task 7 (`RD_PROVIDER`, `AWS_*`, `ANTHROPIC_API_KEY`, `ANTHROPIC_DEFAULT_*_MODEL`).
- Produces: `~/.config/rd/provider`, `~/.config/rd/providers/*.env` (0600), the `remote-dev provider` block in `~/.profile`, `gh` and `aws` on PATH.

- [ ] **Step 1: Install `gh` from GitHub's signed apt repo**

After the `glab` block:

```bash
# --- GitHub CLI (gh): PRs, checks, and git auth for cloning -----------------
if ! command -v gh >/dev/null 2>&1; then
  log "GitHub CLI (gh)"
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
  sudo chmod 0644 /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq gh || warn "Could not install gh — GitHub repos will not work until it is present."
fi

# --- AWS CLI: only needed for the Bedrock SSO auth path ---------------------
# NOTE (found during the container smoke run): awscli is NOT in the Ubuntu
# 24.04 archive — no candidate even with universe — so apt can never satisfy
# this. Use AWS's versioned zip, the same fallback shape as glab's .deb, and
# add `unzip` to the base package list.
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
```

Also replace the bare `"$USER"` uses (docker group, `loginctl enable-linger`)
with `RUN_USER="${USER:-$(id -un)}"` defined next to the config load: `USER` is
not exported by every non-login shell, and `set -u` turns it into a hard abort —
`bootstrap-remote.sh` invokes this through `ssh host cmd`.

- [ ] **Step 2: Write the provider config files**

Replace the `--- Vertex environment ---` section:

```bash
# --- Model provider configuration ------------------------------------------
log "Provider config in ~/.config/rd"
RD_CONFIG_DIR="$HOME/.config/rd"
PROVIDER_DIR="$RD_CONFIG_DIR/providers"
mkdir -p "$PROVIDER_DIR"
chmod 700 "$RD_CONFIG_DIR" "$PROVIDER_DIR"

write_provider() {
  local name="$1"
  shift
  local file="$PROVIDER_DIR/$name.env"
  umask 077
  {
    printf '# Written by bootstrap.sh from rd.env — edit rd.env and re-run.\n'
    printf '%s\n' "$@"
  } > "$file"
  chmod 600 "$file"
  echo "   provider '$name' configured"
}

# Vertex: written whenever a project id is known (the historical default).
if [[ -n "${GCP_PROJECT_ID:-}" ]]; then
  write_provider vertex \
    "export CLAUDE_CODE_USE_VERTEX=1" \
    "export ANTHROPIC_VERTEX_PROJECT_ID=$GCP_PROJECT_ID" \
    "export CLOUD_ML_REGION=$CLOUD_ML_REGION"
fi

# Bedrock: needs a region plus exactly one credential path.
if [[ -n "${AWS_REGION:-}" ]]; then
  bedrock_lines=(
    "export CLAUDE_CODE_USE_BEDROCK=1"
    "export AWS_REGION=$AWS_REGION"
  )
  [[ -n "${AWS_PROFILE:-}" ]] && bedrock_lines+=("export AWS_PROFILE=$AWS_PROFILE")
  [[ -n "${AWS_BEARER_TOKEN_BEDROCK:-}" ]] && bedrock_lines+=("export AWS_BEARER_TOKEN_BEDROCK=$AWS_BEARER_TOKEN_BEDROCK")
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    bedrock_lines+=("export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"
                    "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY")
    [[ -n "${AWS_SESSION_TOKEN:-}" ]] && bedrock_lines+=("export AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN")
  fi
  # Without pins, `opus`/`sonnet` resolve to Claude Code's built-in Bedrock
  # defaults, which may not be enabled in the account.
  [[ -n "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" ]] && bedrock_lines+=("export ANTHROPIC_DEFAULT_OPUS_MODEL=$ANTHROPIC_DEFAULT_OPUS_MODEL")
  [[ -n "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ]] && bedrock_lines+=("export ANTHROPIC_DEFAULT_SONNET_MODEL=$ANTHROPIC_DEFAULT_SONNET_MODEL")
  [[ -n "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" ]] && bedrock_lines+=("export ANTHROPIC_DEFAULT_HAIKU_MODEL=$ANTHROPIC_DEFAULT_HAIKU_MODEL")
  write_provider bedrock "${bedrock_lines[@]}"
fi

# Anthropic: an API key here, or an OAuth token added later by rd-auth.
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  write_provider anthropic "export ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
elif [[ "${RD_PROVIDER:-}" == "anthropic" && ! -f "$PROVIDER_DIR/anthropic.env" ]]; then
  write_provider anthropic "# rd-auth adds CLAUDE_CODE_OAUTH_TOKEN here on the subscription path."
fi

RD_PROVIDER="${RD_PROVIDER:-vertex}"
if [[ ! -r "$PROVIDER_DIR/$RD_PROVIDER.env" ]]; then
  warn "Default provider '$RD_PROVIDER' has no config — set its values in rd.env and re-run."
fi
printf '%s\n' "$RD_PROVIDER" > "$RD_CONFIG_DIR/provider"
```

- [ ] **Step 3: Replace the profile block with the provider switch**

```bash
log "Provider switch in ~/.profile"
MARK_BEGIN="# >>> remote-dev provider >>>"
MARK_END="# <<< remote-dev provider <<<"
# Remove the previous block AND the pre-multi-provider Vertex block, then
# re-append (idempotent, and it migrates an existing VM).
sed -i "/# >>> remote-dev vertex >>>/,/# <<< remote-dev vertex <<</d" "$HOME/.profile" 2>/dev/null || true
sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$HOME/.profile" 2>/dev/null || true
cat >> "$HOME/.profile" <<EOF
$MARK_BEGIN
export PATH="\$HOME/.local/bin:\$PATH"
# tmux starts panes as login shells, so this is where a session picks up its
# model provider. rd-start overrides it with: tmux new-session -e RD_PROVIDER=…
RD_PROVIDER="\${RD_PROVIDER:-\$(cat "\$HOME/.config/rd/provider" 2>/dev/null || echo vertex)}"
if [ -r "\$HOME/.config/rd/providers/\$RD_PROVIDER.env" ]; then
  . "\$HOME/.config/rd/providers/\$RD_PROVIDER.env"
fi
export RD_PROVIDER
$MARK_END
EOF
```

Note the config load at the top of the file already `source`s `rd.env`, so all
the new keys are in scope; only `CLOUD_ML_REGION` keeps its default and the
`GCP_PROJECT_ID` prompt must become conditional:

```bash
CLOUD_ML_REGION="${CLOUD_ML_REGION:-global}"
RD_PROVIDER="${RD_PROVIDER:-vertex}"
if [[ "$RD_PROVIDER" == "vertex" && -z "${GCP_PROJECT_ID:-}" ]]; then
  read -rp "GCP (Vertex) project id: " GCP_PROJECT_ID
fi
```

- [ ] **Step 4: Update the closing next-steps text**

Replace the Vertex/GitLab lines with provider- and forge-neutral ones:

```
  2) One-time authorizations (provider + forge + git author):  rd-auth
  3) Start a session on the default provider:                  rd-start <project>
     …or on another one:                                       rd-start <project> --provider bedrock
```

- [ ] **Step 5: Syntax-check and checkpoint**

Run: `bash -n bootstrap.sh` then the full test suite.
Expected: clean parse, all suites pass. (`bootstrap.sh` itself is only exercised by the VM smoke test.)

---

### Task 6: Forge-aware first clone in `bootstrap-remote.sh`

**Files:**
- Modify: `bootstrap-remote.sh` (lines 26-30, the `clone_url` construction)

**Interfaces:**
- Consumes: `REPO_URL`, `GIT_CLONE_TOKEN`, and the optional `FORGE` key from `rd.env`.
- Produces: a clone URL whose credential prefix matches the forge.

- [ ] **Step 1: Branch the credential prefix on the forge**

```bash
# Authenticated URL for the first clone, if a token is provided. GitLab wants
# oauth2:<token>, GitHub wants x-access-token:<token>; the token is stripped
# from the stored remote afterwards either way.
clone_url="$REPO_URL"
if [[ -n "${GIT_CLONE_TOKEN:-}" ]]; then
  repo_host="${REPO_URL#https://}"
  repo_host="${repo_host%%/*}"
  forge="${FORGE:-}"
  if [[ -z "$forge" ]]; then
    case "$repo_host" in
      github.com|*github*) forge="github" ;;
      *) forge="gitlab" ;;
    esac
  fi
  case "$forge" in
    github) clone_user="x-access-token" ;;
    gitlab) clone_user="oauth2" ;;
    *) echo "Unknown FORGE '$forge' in rd.env (expected gitlab or github)." >&2; exit 1 ;;
  esac
  clone_url="https://${clone_user}:${GIT_CLONE_TOKEN}@${REPO_URL#https://}"
fi
```

- [ ] **Step 2: Update the closing hint**

`rd-auth  # one-time: Vertex + GitLab + Jira` becomes
`rd-auth  # one-time: model provider + forge + git author`.

- [ ] **Step 3: Syntax-check and checkpoint**

Run: `bash -n bootstrap-remote.sh` then the full test suite.

---

### Task 7: Configuration surface and documentation

**Files:**
- Modify: `rd.env.example`
- Modify: `README.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: every key introduced in Tasks 3-6.
- Produces: the documented configuration contract. A flag that appears in no doc is not finished.

- [ ] **Step 1: Extend `rd.env.example`**

Add, after the existing repo-delivery block:

```bash
# --- Forge: which one REPO_URL lives on (blank = infer from the host) -------
# github.com -> github, gitlab.com -> gitlab; set it explicitly for a
# self-hosted host, where the name alone cannot tell them apart.
FORGE=""

# --- VM-side: which model provider new sessions use by default -------------
# vertex | bedrock | anthropic. Override per session: rd-start <p> --provider X
RD_PROVIDER="vertex"

# --- Provider: GCP Vertex --------------------------------------------------
GCP_PROJECT_ID="your-vertex-project-id"
CLOUD_ML_REGION="global"

# --- Provider: Amazon Bedrock ----------------------------------------------
# Pick ONE credential path. AWS_PROFILE (SSO) is preferred — no static secret
# on the VM; refresh it with: rd-auth --provider bedrock
AWS_REGION=""
AWS_PROFILE=""
AWS_BEARER_TOKEN_BEDROCK=""
AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
# Without pins, `opus`/`sonnet` resolve to Claude Code's built-in Bedrock
# defaults, which may not be enabled in your account.
ANTHROPIC_DEFAULT_OPUS_MODEL=""
ANTHROPIC_DEFAULT_SONNET_MODEL=""
ANTHROPIC_DEFAULT_HAIKU_MODEL=""

# --- Provider: direct Anthropic API ----------------------------------------
# Leave empty to use a Claude subscription instead — rd-auth will run
# `claude setup-token` and store the OAuth token outside this file.
ANTHROPIC_API_KEY=""
```

Move the existing `GCP_PROJECT_ID`/`CLOUD_ML_REGION` lines into the Vertex block rather than duplicating them.

- [ ] **Step 2: Update `README.md`**

- The Layout block gains nothing new, but the runbook needs: the provider
  section (choose in `rd.env`, override with `rd-start --provider`, see it in
  `rd-list`), the note that a running session's provider cannot change, and the
  GitHub half of the forge story (`gh` is installed, `rd-auth` logs in, `gh pr
  create` works from a GitHub checkout).
- Add the Bedrock caveats: model pins, and WebSearch being unavailable there.

- [ ] **Step 3: Update `AGENTS.md`**

- "What this repo is": models are reached through **one of** Vertex, Bedrock, or
  the Anthropic API, selected per VM and overridable per session.
- "Integrations available on the VM": add `gh` beside `glab`, and note that the
  git credential helper is host-scoped so the two never answer for each other.
- "Conventions": add the provider-file rule — secrets live in
  `~/.config/rd/providers/*.env` at 0600; only `RD_PROVIDER` crosses the tmux
  boundary.
- "Build & test": add `bash tests/test-rd-provider.sh`.
- "Merging MRs" becomes "Merging MRs and PRs" with the `gh pr merge` caveat
  beside the existing `glab mr merge` one.

- [ ] **Step 4: Final checkpoint**

Run the full test suite plus `shellcheck -S warning bootstrap.sh bootstrap-remote.sh connect.sh sessions.sh sync-memory.sh bin/rd-*` if shellcheck is available.
Expected: suites pass; shellcheck reports nothing new.

---

## Deferred to the VM smoke test

None of the automated tests exercise `bootstrap.sh`, `bootstrap-remote.sh`, or a
real `claude` call. On a throwaway VM, after `bootstrap-remote.sh`:

1. `rd-auth` for the default provider, then `rd-auth --provider bedrock`.
2. `rd-start demo` and `rd-start demo --session alt --provider anthropic`;
   confirm `rd-list` shows both providers and that `claude` reaches a model in
   each pane.
3. Clone one GitHub and one GitLab repo; confirm `git push` works in both and
   that `gh pr create` / `glab mr create` resolve the forge from the remote.
4. Re-run `bootstrap.sh` and confirm `~/.profile` still holds exactly one
   `remote-dev provider` block and no `remote-dev vertex` block.
