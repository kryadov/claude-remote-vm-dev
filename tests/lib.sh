# shellcheck shell=bash
# Shared helpers for the rd-* test scripts.
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Installs the tmux/ssh stubs into <dir>, which the caller puts first on PATH.
# They are copied (not used in place) so the executable bit is set regardless of
# how the repo was checked out.
rd_test_install_stubs() {
  local dest="$1" stubs
  stubs="$(cd "$(dirname "${BASH_SOURCE[0]}")/stubs" && pwd)"
  mkdir -p "$dest"
  install -m 0755 "$stubs/tmux" "$stubs/ssh" "$dest/"
}

rd_test_new_repo() {
  local repo="$1"
  git init -q -b main "$repo"
  git -C "$repo" config user.name "Test User"
  git -C "$repo" config user.email "test@example.invalid"
  printf 'initial\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m initial
}
