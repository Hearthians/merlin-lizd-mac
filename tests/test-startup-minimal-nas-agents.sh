#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sut="$repo_root/startup-minimal-nas-agents.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_shared_codex() {
  local nas_root="$1"
  mkdir -p "$nas_root/.agent-shared/codex/sessions" \
    "$nas_root/.agent-shared/codex/skills"
  printf '{}\n' >"$nas_root/.agent-shared/codex/auth.json"
  printf '[projects]\n' >"$nas_root/.agent-shared/codex/config.toml.template"
}

run_helper() {
  local helper="$1"
  local target_home="$2"
  local nas_root="$3"
  local runtime_root="$4"

  HOME="$target_home" USER="$(id -un)" \
    SHARED_HOME="$nas_root" \
    SHARED_CODEX_HOME="$nas_root/.agent-shared/codex" \
    SHARED_CODEX_CONFIG_TEMPLATE="$nas_root/.agent-shared/codex/config.toml.template" \
    LIZD_AGENT_RUNTIME_ROOT="$runtime_root" \
    CODEX_HOME="$runtime_root/codex" \
    CODEX_SQLITE_HOME="$runtime_root/codex-sqlite" \
    XDG_CACHE_HOME="$runtime_root/cache" \
    LIZD_ALLOW_NON_NFS_SHARED_HOME=1 \
    "$helper"
}

assert_runtime() {
  local runtime_root="$1"
  local shared_codex="$2"
  local codex_home="$runtime_root/codex"

  test "$(readlink "$codex_home/auth.json")" = "$shared_codex/auth.json" || \
    die "auth.json does not point at the canonical shared file"
  test "$(readlink "$codex_home/sessions")" = "$shared_codex/sessions" || \
    die "sessions does not point at the canonical shared directory"
  test "$(readlink "$codex_home/skills")" = "$shared_codex/skills" || \
    die "skills does not point at the canonical shared directory"
  test -f "$codex_home/config.toml" || die "local config.toml was not installed"
  grep -Fx '[projects]' "$codex_home/config.toml" >/dev/null || \
    die "local config.toml is not a copy of the shared template"
  ! grep -Eq '^[[:space:]]*sqlite_home[[:space:]]*=' "$codex_home/config.toml" || \
    die "config.toml still contains sqlite_home"
  test -f "$codex_home/.lizd-runtime-v1" || die "runtime marker is missing"
  if find "$codex_home" -maxdepth 1 -name '.config.toml.tmp.*' -print | grep -q .; then
    die "temporary config files were left behind"
  fi
}

home="$tmp/home/tiger"
nas="$tmp/nas/lizd"
runtime="$tmp/worker-tmp"
mkdir -p "$home/.claude/existing" "$home/.agent-local/nvm" \
  "$home/.agent-local/cache/npm" "$home/.nvm" "$home/.npm" "$runtime"
printf 'keep-claude-dir\n' >"$home/.claude/existing/state"
printf 'keep-claude-json\n' >"$home/.claude.json"
printf 'keep-local-history\n' >"$home/.zsh_history"
printf 'keep-agent-local-nvm\n' >"$home/.agent-local/nvm/state"
printf 'keep-agent-local-npm-cache\n' >"$home/.agent-local/cache/npm/state"
printf 'keep-home-nvm\n' >"$home/.nvm/state"
printf 'keep-home-npm\n' >"$home/.npm/state"
make_shared_codex "$nas"

narrow_snapshot="$tmp/narrow-snapshot"
mkdir -p "$narrow_snapshot"
cp -R "$home/.claude" "$narrow_snapshot/claude"
cp "$home/.claude.json" "$narrow_snapshot/claude.json"
cp "$home/.zsh_history" "$narrow_snapshot/zsh_history"
cp -R "$home/.agent-local/nvm" "$narrow_snapshot/agent-local-nvm"
cp -R "$home/.agent-local/cache/npm" "$narrow_snapshot/agent-local-npm-cache"
cp -R "$home/.nvm" "$narrow_snapshot/home-nvm"
cp -R "$home/.npm" "$narrow_snapshot/home-npm"

TARGET_USER="$(id -un)" TARGET_HOME="$home" SHARED_HOME="$nas" \
  LIZD_AGENT_RUNTIME_PARENT="$runtime" INSTALL_SYSTEM_PACKAGES=0 INSTALL_NODE_TOOLS=0 \
  CONFIGURE_CLAUDE_SHARING=0 LIZD_ALLOW_NON_NFS_SHARED_HOME=1 \
  "$sut" --install-codex-runtime-only

# The narrow entry point installs only the Codex helper and its two shell
# blocks. Existing Claude/history/NVM/package state is byte-for-byte stable.
diff -r "$narrow_snapshot/claude" "$home/.claude" >/dev/null || \
  die "narrow install modified .claude"
test ! -L "$home/.claude.json" || die "narrow install replaced .claude.json with a symlink"
cmp "$narrow_snapshot/claude.json" "$home/.claude.json" >/dev/null || \
  die "narrow install modified .claude.json"
cmp "$narrow_snapshot/zsh_history" "$home/.zsh_history" >/dev/null || \
  die "narrow install modified .zsh_history"
diff -r "$narrow_snapshot/agent-local-nvm" "$home/.agent-local/nvm" >/dev/null || \
  die "narrow install modified LOCAL_STATE_ROOT nvm"
diff -r "$narrow_snapshot/agent-local-npm-cache" "$home/.agent-local/cache/npm" >/dev/null || \
  die "narrow install modified the npm cache"
diff -r "$narrow_snapshot/home-nvm" "$home/.nvm" >/dev/null || \
  die "narrow install modified ~/.nvm"
diff -r "$narrow_snapshot/home-npm" "$home/.npm" >/dev/null || \
  die "narrow install modified ~/.npm"
test ! -e "$home/.agent-local/codex" || die "narrow install created the legacy Codex home"
test ! -e "$home/.agent-local/codex-sqlite" || die "narrow install created the legacy SQLite home"
test ! -e "$home/.local/lib/node_modules" || die "narrow install installed Node packages"

helper="$home/.local/bin/lizd-codex-runtime-init"
test -x "$helper" || die "runtime initializer was not installed"
for rc in "$home/.zshenv" "$home/.bashrc"; do
  test -f "$rc" || die "managed shell file is missing: $rc"
  if grep -Eq 'export[[:space:]]+LIZD_ALLOW_NON_NFS_SHARED_HOME' "$rc"; then
    die "the production shell block enables the synthetic NFS bypass"
  fi
done

HOME="$home" LIZD_AGENT_RUNTIME_PARENT="$runtime" \
  LIZD_ALLOW_NON_NFS_SHARED_HOME=1 zsh -dfc \
  'source "$HOME/.zshenv"; printf "%s\n" "$CODEX_HOME" "$CODEX_SQLITE_HOME" "$XDG_CACHE_HOME"' \
  >"$tmp/paths"

runtime_root="$runtime/lizd-agent-runtime-$(id -un)"
grep -Fx "$runtime_root/codex" "$tmp/paths" >/dev/null || die "CODEX_HOME is not runtime-local"
grep -Fx "$runtime_root/codex-sqlite" "$tmp/paths" >/dev/null || die "CODEX_SQLITE_HOME is not runtime-local"
grep -Fx "$runtime_root/cache" "$tmp/paths" >/dev/null || die "XDG_CACHE_HOME is not runtime-local"
assert_runtime "$runtime_root" "$nas/.agent-shared/codex"

# Bash sources the same managed runtime block successfully.
bash_parent="$tmp/bash-runtime"
mkdir -p "$bash_parent"
HOME="$home" LIZD_AGENT_RUNTIME_PARENT="$bash_parent" \
  LIZD_ALLOW_NON_NFS_SHARED_HOME=1 bash --noprofile --norc -c \
  'source "$HOME/.bashrc"; printf "%s\n" "$CODEX_HOME" "$CODEX_SQLITE_HOME" "$XDG_CACHE_HOME"' \
  >"$tmp/bash-paths"
bash_root="$bash_parent/lizd-agent-runtime-$(id -un)"
grep -Fx "$bash_root/codex" "$tmp/bash-paths" >/dev/null || die "bash CODEX_HOME is not runtime-local"
grep -Fx "$bash_root/codex-sqlite" "$tmp/bash-paths" >/dev/null || \
  die "bash CODEX_SQLITE_HOME is not runtime-local"
grep -Fx "$bash_root/cache" "$tmp/bash-paths" >/dev/null || die "bash XDG_CACHE_HOME is not runtime-local"
assert_runtime "$bash_root" "$nas/.agent-shared/codex"

# An inherited shared CODEX_HOME must never survive the managed block.
HOME="$home" LIZD_AGENT_RUNTIME_PARENT="$runtime" \
  CODEX_HOME="$nas/.agent-shared/codex" CODEX_SQLITE_HOME="$nas/.agent-shared/codex" \
  LIZD_ALLOW_NON_NFS_SHARED_HOME=1 zsh -dfc \
  'source "$HOME/.zshenv"; printf "%s\n" "$CODEX_HOME" "$CODEX_SQLITE_HOME"' \
  >"$tmp/inherited-paths"
grep -Fx "$runtime_root/codex" "$tmp/inherited-paths" >/dev/null || \
  die "an inherited shared CODEX_HOME was not overridden"
grep -Fx "$runtime_root/codex-sqlite" "$tmp/inherited-paths" >/dev/null || \
  die "an inherited shared CODEX_SQLITE_HOME was not overridden"

# Eight shells race the same fresh runtime. Every initializer must succeed.
concurrent_parent="$tmp/concurrent-runtime"
mkdir -p "$concurrent_parent"
pids=()
i=1
while [[ "$i" -le 8 ]]; do
  (
    HOME="$home" LIZD_AGENT_RUNTIME_PARENT="$concurrent_parent" \
      LIZD_ALLOW_NON_NFS_SHARED_HOME=1 zsh -dfc \
      'source "$HOME/.zshenv"; test "$CODEX_HOME" != /dev/null; test -f "$CODEX_HOME/.lizd-runtime-v1"'
  ) >"$tmp/concurrent-$i.out" 2>"$tmp/concurrent-$i.err" &
  pids+=("$!")
  i=$((i + 1))
done
for pid in "${pids[@]}"; do
  wait "$pid" || die "one of eight concurrent shell initializers failed"
done
concurrent_root="$concurrent_parent/lizd-agent-runtime-$(id -un)"
assert_runtime "$concurrent_root" "$nas/.agent-shared/codex"

# A shared template carrying the deprecated sqlite_home key is unsafe. It must
# fail before a local config or temporary copy is written.
sqlite_nas="$tmp/sqlite-template/nas"
make_shared_codex "$sqlite_nas"
printf 'sqlite_home = "/shared/unsafe.sqlite"\n' >> \
  "$sqlite_nas/.agent-shared/codex/config.toml.template"
sqlite_root="$tmp/sqlite-template/runtime"
if run_helper "$helper" "$home" "$sqlite_nas" "$sqlite_root"; then
  die "a shared template containing sqlite_home was accepted"
fi
test ! -e "$sqlite_root/codex/config.toml" || \
  die "unsafe shared template produced a local config"
if [[ -d "$sqlite_root/codex" ]] && \
  find "$sqlite_root/codex" -maxdepth 1 -name '.config.toml.tmp.*' -print | grep -q .; then
  die "unsafe shared template left a temporary local config"
fi

# Synthetic, non-NFS fixtures are rejected unless the bypass is explicit.
no_bypass_home="$tmp/no-bypass-home"
mkdir -p "$no_bypass_home"
if (
  unset LIZD_ALLOW_NON_NFS_SHARED_HOME
  TARGET_USER="$(id -un)" TARGET_HOME="$no_bypass_home" SHARED_HOME="$nas" \
    LIZD_AGENT_RUNTIME_PARENT="$runtime" INSTALL_SYSTEM_PACKAGES=0 INSTALL_NODE_TOOLS=0 \
    CONFIGURE_CLAUDE_SHARING=0 "$sut" --install-codex-runtime-only
); then
  die "synthetic shared home was accepted without an explicit bypass"
fi

# The narrow installer must not turn a missing local directory into a fake NAS.
unmounted_nas="$tmp/unmounted-production/nas"
unmounted_home="$tmp/unmounted-home"
mkdir -p "$unmounted_home"
if (
  unset LIZD_ALLOW_NON_NFS_SHARED_HOME
  TARGET_USER="$(id -un)" TARGET_HOME="$unmounted_home" SHARED_HOME="$unmounted_nas" \
    LIZD_AGENT_RUNTIME_PARENT="$runtime" INSTALL_SYSTEM_PACKAGES=0 INSTALL_NODE_TOOLS=0 \
    CONFIGURE_CLAUDE_SHARING=0 "$sut" --install-codex-runtime-only
); then
  die "an unavailable shared home was accepted"
fi
test ! -e "$unmounted_nas" || die "the unavailable shared home was created locally"

# A normal file/directory at a canonical local link path is a hard failure and
# must remain byte-for-byte unchanged.
for conflict in auth.json sessions skills; do
  conflict_root="$tmp/conflict-$conflict"
  mkdir -p "$conflict_root/codex"
  expected="$tmp/expected-$conflict"
  if [[ "$conflict" == auth.json ]]; then
    printf 'do-not-touch-auth\nsecond-line\n' >"$conflict_root/codex/$conflict"
    cp "$conflict_root/codex/$conflict" "$expected"
  else
    mkdir -p "$conflict_root/codex/$conflict/nested"
    printf 'do-not-touch-%s\n' "$conflict" >"$conflict_root/codex/$conflict/nested/payload"
    cp -R "$conflict_root/codex/$conflict" "$expected"
  fi

  if run_helper "$helper" "$home" "$nas" "$conflict_root"; then
    die "$conflict conflict did not fail closed"
  fi
  test ! -L "$conflict_root/codex/$conflict" || die "$conflict conflict was replaced by a symlink"
  if [[ "$conflict" == auth.json ]]; then
    cmp "$expected" "$conflict_root/codex/$conflict" >/dev/null || \
      die "$conflict conflict changed"
  else
    diff -r "$expected" "$conflict_root/codex/$conflict" >/dev/null || \
      die "$conflict conflict changed"
  fi
  if find "$conflict_root/codex" -maxdepth 1 -name '.config.toml.tmp.*' -print | grep -q .; then
    die "$conflict failure left a temporary config"
  fi
done

# Missing canonical NAS inputs are failures; the helper must not manufacture
# the missing path or any other NAS entry.
for missing in auth.json sessions skills config.toml.template; do
  missing_nas="$tmp/missing-$missing/nas"
  make_shared_codex "$missing_nas"
  if [[ -d "$missing_nas/.agent-shared/codex/$missing" ]]; then
    rmdir "$missing_nas/.agent-shared/codex/$missing"
  else
    rm "$missing_nas/.agent-shared/codex/$missing"
  fi
  before_listing="$(find "$missing_nas" -print | LC_ALL=C sort)"
  missing_root="$tmp/missing-$missing/runtime"
  if run_helper "$helper" "$home" "$missing_nas" "$missing_root"; then
    die "missing shared $missing did not fail closed"
  fi
  test ! -e "$missing_nas/.agent-shared/codex/$missing" || \
    die "missing shared $missing was created"
  after_listing="$(find "$missing_nas" -print | LC_ALL=C sort)"
  test "$before_listing" = "$after_listing" || \
    die "missing shared $missing caused a canonical NAS mutation"
done

# If the initializer fails during shell startup, both Codex roots become an
# unusable fail-closed value rather than falling back to shared state.
mv "$nas/.agent-shared/codex/auth.json" "$nas/.agent-shared/codex/auth.json.offline"
for shell_kind in zsh bash; do
  failed_paths="$tmp/failed-paths-$shell_kind"
  if [[ "$shell_kind" == zsh ]]; then
    if ! HOME="$home" LIZD_AGENT_RUNTIME_PARENT="$tmp/failing-runtime-$shell_kind" \
      CODEX_HOME="$nas/.agent-shared/codex" CODEX_SQLITE_HOME="$nas/.agent-shared/codex" \
      LIZD_ALLOW_NON_NFS_SHARED_HOME=1 zsh -dfc \
      'source "$HOME/.zshenv"; printf "continued\n%s\n" "$CODEX_HOME" "$CODEX_SQLITE_HOME"' \
      >"$failed_paths"; then
      mv "$nas/.agent-shared/codex/auth.json.offline" "$nas/.agent-shared/codex/auth.json"
      die "zsh managed block did not continue after helper failure"
    fi
  else
    if ! HOME="$home" LIZD_AGENT_RUNTIME_PARENT="$tmp/failing-runtime-$shell_kind" \
      CODEX_HOME="$nas/.agent-shared/codex" CODEX_SQLITE_HOME="$nas/.agent-shared/codex" \
      LIZD_ALLOW_NON_NFS_SHARED_HOME=1 bash --noprofile --norc -c \
      'source "$HOME/.bashrc"; printf "continued\n%s\n" "$CODEX_HOME" "$CODEX_SQLITE_HOME"' \
      >"$failed_paths"; then
      mv "$nas/.agent-shared/codex/auth.json.offline" "$nas/.agent-shared/codex/auth.json"
      die "bash managed block did not continue after helper failure"
    fi
  fi
  test "$(sed -n '1p' "$failed_paths")" = continued || \
    die "$shell_kind did not continue after helper failure"
  test "$(grep -Fxc /dev/null "$failed_paths")" -eq 2 || \
    die "$shell_kind helper failure did not set both Codex roots to /dev/null"
done
mv "$nas/.agent-shared/codex/auth.json.offline" "$nas/.agent-shared/codex/auth.json"

printf 'PASS: isolated Codex runtime initialization\n'
