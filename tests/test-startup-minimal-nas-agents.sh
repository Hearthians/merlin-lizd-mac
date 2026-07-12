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

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
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

run_helper_with_command_path() (
  local helper="$1"
  local target_home="$2"
  local nas_root="$3"
  local runtime_root="$4"
  local command_path="$5"
  local synthetic_bypass="$6"
  local current_user

  current_user="$(id -un)"
  export HOME="$target_home"
  export USER="$current_user"
  export SHARED_HOME="$nas_root"
  export SHARED_CODEX_HOME="$nas_root/.agent-shared/codex"
  export SHARED_CODEX_CONFIG_TEMPLATE="$nas_root/.agent-shared/codex/config.toml.template"
  export LIZD_AGENT_RUNTIME_ROOT="$runtime_root"
  export CODEX_HOME="$runtime_root/codex"
  export CODEX_SQLITE_HOME="$runtime_root/codex-sqlite"
  export XDG_CACHE_HOME="$runtime_root/cache"
  export PATH="$command_path"
  if [[ "$synthetic_bypass" == 1 ]]; then
    export LIZD_ALLOW_NON_NFS_SHARED_HOME=1
  else
    unset LIZD_ALLOW_NON_NFS_SHARED_HOME
  fi
  /bin/bash "$helper"
)

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

cat >"$home/.zshenv" <<'EOF'
# keep-zsh-prefix
# >>> minimal-nas-agents
export NVM_DIR="$HOME/.agent-local/nvm"
export CODEX_HOME="$HOME/.agent-local/codex"
export CODEX_SQLITE_HOME="$HOME/.agent-local/codex-sqlite"
export XDG_CACHE_HOME="$HOME/.agent-local/cache"
export PATH="$HOME/.local/bin:$PATH"
# keep-zsh-legacy-line
# <<< minimal-nas-agents
# keep-zsh-suffix
EOF

cat >"$home/.bashrc" <<'EOF'
# keep-bash-prefix
# >>> minimal-nas-agents
export NVM_DIR="$HOME/.agent-local/nvm"
export CODEX_HOME="$HOME/.agent-local/codex"
export CODEX_SQLITE_HOME="$HOME/.agent-local/codex-sqlite"
export XDG_CACHE_HOME="$HOME/.agent-local/cache"
export PATH="$HOME/.local/bin:$PATH"
# keep-bash-legacy-line
# <<< minimal-nas-agents
# bash-noninteractive-guard
[[ $- == *i* ]] || return
# >>> keep-unrelated-block
export CODEX_HOME="$HOME/keep-outside-legacy"
# <<< keep-unrelated-block
EOF

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

  legacy_body="$(awk '
    $0 == "# >>> minimal-nas-agents" { legacy = 1; next }
    legacy && $0 == "# <<< minimal-nas-agents" { exit }
    legacy { print }
  ' "$rc")"
  if grep -Eq '^[[:space:]]*export[[:space:]]+(CODEX_HOME|CODEX_SQLITE_HOME|XDG_CACHE_HOME)=' \
    <<<"$legacy_body"; then
    die "legacy Codex runtime exports survived in $rc"
  fi
  grep -Fx 'export NVM_DIR="$HOME/.agent-local/nvm"' <<<"$legacy_body" >/dev/null || \
    die "legacy NVM export was not preserved in $rc"
  grep -Fx 'export PATH="$HOME/.local/bin:$PATH"' <<<"$legacy_body" >/dev/null || \
    die "legacy PATH export was not preserved in $rc"
done
grep -Fx '# keep-zsh-prefix' "$home/.zshenv" >/dev/null || die "zsh prefix was not preserved"
grep -Fx '# keep-zsh-legacy-line' "$home/.zshenv" >/dev/null || \
  die "unrelated zsh legacy content was not preserved"
grep -Fx '# keep-zsh-suffix' "$home/.zshenv" >/dev/null || die "zsh suffix was not preserved"
grep -Fx '# keep-bash-prefix' "$home/.bashrc" >/dev/null || die "bash prefix was not preserved"
grep -Fx '# keep-bash-legacy-line' "$home/.bashrc" >/dev/null || \
  die "unrelated bash legacy content was not preserved"
grep -Fx 'export CODEX_HOME="$HOME/keep-outside-legacy"' "$home/.bashrc" >/dev/null || \
  die "Codex export outside the legacy block was removed"
bash_runtime_line="$(grep -n -m1 '^# >>> minimal-nas-agents-codex-runtime$' "$home/.bashrc" | cut -d: -f1)"
bash_return_line="$(grep -n -m1 '^\[\[ \$- == \*i\* \]\] || return$' "$home/.bashrc" | cut -d: -f1)"
[[ -n "$bash_runtime_line" && -n "$bash_return_line" && "$bash_runtime_line" -lt "$bash_return_line" ]] || \
  die "bash Codex runtime block was not installed before the early return"

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
real_flock="$(command -v flock || true)"
concurrent_path="$PATH"
flock_probe_log="$tmp/flock-probe.log"
if [[ -n "$real_flock" ]]; then
  flock_probe_bin="$tmp/flock-probe-bin"
  mkdir -p "$flock_probe_bin"
  cat >"$flock_probe_bin/flock" <<'EOF'
#!/bin/sh
printf '%s\n' "$$" >>"$LIZD_TEST_FLOCK_LOG"
exec "$LIZD_TEST_REAL_FLOCK" "$@"
EOF
  chmod 700 "$flock_probe_bin/flock"
  concurrent_path="$flock_probe_bin:$PATH"
fi
pids=()
i=1
while [[ "$i" -le 8 ]]; do
  (
    HOME="$home" PATH="$concurrent_path" LIZD_AGENT_RUNTIME_PARENT="$concurrent_parent" \
      LIZD_TEST_REAL_FLOCK="$real_flock" LIZD_TEST_FLOCK_LOG="$flock_probe_log" \
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
if [[ -n "$real_flock" ]]; then
  test "$(wc -l <"$flock_probe_log" | tr -d '[:space:]')" -ge 8 || \
    die "Linux concurrent initialization did not send every shell through flock"

  flock_release_root="$tmp/flock-release-runtime"
  mkdir -p "$flock_release_root/codex" "$flock_release_root/codex-sqlite" \
    "$flock_release_root/cache"
  chmod 700 "$flock_release_root" "$flock_release_root/codex" \
    "$flock_release_root/codex-sqlite" "$flock_release_root/cache"
  flock_holder_ready="$tmp/flock-holder-ready"
  (
    exec 9<"$flock_release_root"
    "$real_flock" -x 9
    : >"$flock_holder_ready"
    while :; do sleep 1; done
  ) &
  flock_holder_pid="$!"
  for _ in $(seq 1 200); do
    [[ -e "$flock_holder_ready" ]] && break
    kill -0 "$flock_holder_pid" 2>/dev/null || die "flock holder exited before acquiring the lock"
    sleep 0.01
  done
  [[ -e "$flock_holder_ready" ]] || die "flock holder did not acquire the runtime lock"

  flock_release_log="$tmp/flock-release-probe.log"
  PATH="$concurrent_path" LIZD_TEST_REAL_FLOCK="$real_flock" \
    LIZD_TEST_FLOCK_LOG="$flock_release_log" \
    run_helper "$helper" "$home" "$nas" "$flock_release_root" \
    >"$tmp/flock-release-helper.out" 2>"$tmp/flock-release-helper.err" &
  flock_waiter_pid="$!"
  for _ in $(seq 1 200); do
    [[ -s "$flock_release_log" ]] && break
    kill -0 "$flock_waiter_pid" 2>/dev/null || \
      die "runtime helper exited instead of waiting for flock"
    sleep 0.01
  done
  [[ -s "$flock_release_log" ]] || die "runtime helper never attempted flock"
  kill -0 "$flock_waiter_pid" 2>/dev/null || die "runtime helper did not wait for the held lock"
  kill -9 "$flock_holder_pid"
  wait "$flock_holder_pid" 2>/dev/null || true
  wait "$flock_waiter_pid" || \
    die "runtime helper did not recover after the flock owner exited"
  assert_runtime "$flock_release_root" "$nas/.agent-shared/codex"
fi

# Production must never fall back to a stale mkdir lock when flock is absent.
# A synthetic fixture may use that fallback so this suite remains portable to
# macOS, where flock is not installed by default.
no_flock_bin="$tmp/no-flock-bin"
mkdir -p "$no_flock_bin"
for required_tool in chmod cp grep id ln mkdir mktemp mv readlink rm rmdir sleep stat; do
  required_tool_path="$(command -v "$required_tool")" || \
    die "test prerequisite is missing: $required_tool"
  ln -s "$required_tool_path" "$no_flock_bin/$required_tool"
done
cat >"$no_flock_bin/findmnt" <<'EOF'
#!/bin/sh
printf 'nfs\n'
EOF
chmod 700 "$no_flock_bin/findmnt"

no_flock_production_root="$tmp/no-flock-production-runtime"
if run_helper_with_command_path "$helper" "$home" "$nas" \
  "$no_flock_production_root" "$no_flock_bin" 0 \
  >"$tmp/no-flock-production.out" 2>"$tmp/no-flock-production.err"; then
  die "production runtime initialization succeeded without flock"
fi
grep -F 'flock is required for production runtime initialization' \
  "$tmp/no-flock-production.err" >/dev/null || \
  die "production runtime initialization failed for the wrong reason when flock was absent"

no_flock_synthetic_root="$tmp/no-flock-synthetic-runtime"
run_helper_with_command_path "$helper" "$home" "$nas" \
  "$no_flock_synthetic_root" "$no_flock_bin" 1
assert_runtime "$no_flock_synthetic_root" "$nas/.agent-shared/codex"

# The narrow installer must propagate ownership failures for exactly the
# helper and the two managed rc files. The injected command is an executable
# adapter: successful calls delegate to real chown and the selected call exits
# nonzero after recording its complete argv.
chown_probe="$tmp/chown-probe"
cat >"$chown_probe" <<'EOF'
#!/bin/sh
call_count=0
if [ -f "$LIZD_TEST_CHOWN_STATE" ]; then
  IFS= read -r call_count <"$LIZD_TEST_CHOWN_STATE"
fi
call_count=$((call_count + 1))
printf '%s\n' "$call_count" >"$LIZD_TEST_CHOWN_STATE"
{
  printf 'CALL'
  for argument in "$@"; do
    printf '\t%s' "$argument"
  done
  printf '\n'
} >>"$LIZD_TEST_CHOWN_LOG"
if [ "$call_count" -eq "$LIZD_TEST_CHOWN_FAIL_AT" ]; then
  exit 73
fi
exec "$LIZD_TEST_REAL_CHOWN" "$@"
EOF
chmod 700 "$chown_probe"
real_chown="$(command -v chown)"
target_ownership="$(id -un):$(id -gn)"

for fail_at in 1 2; do
  chown_case="$tmp/chown-failure-$fail_at"
  chown_home="$chown_case/home"
  chown_nas="$chown_case/nas"
  chown_log="$chown_case/chown.log"
  chown_state="$chown_case/chown.state"
  mkdir -p "$chown_home"
  make_shared_codex "$chown_nas"
  if TARGET_USER="$(id -un)" TARGET_HOME="$chown_home" SHARED_HOME="$chown_nas" \
    LIZD_AGENT_RUNTIME_PARENT="$chown_case/runtime" INSTALL_SYSTEM_PACKAGES=0 \
    INSTALL_NODE_TOOLS=0 CONFIGURE_CLAUDE_SHARING=0 LIZD_ALLOW_NON_NFS_SHARED_HOME=1 \
    LIZD_CHOWN_COMMAND="$chown_probe" LIZD_TEST_CHOWN_LOG="$chown_log" \
    LIZD_TEST_CHOWN_STATE="$chown_state" LIZD_TEST_CHOWN_FAIL_AT="$fail_at" \
    LIZD_TEST_REAL_CHOWN="$real_chown" "$sut" --install-codex-runtime-only; then
    die "narrow installer ignored chown failure on call $fail_at"
  fi

  chown_expected="$chown_case/chown.expected"
  printf 'CALL\t%s\t%s\n' "$target_ownership" \
    "$chown_home/.local/bin/lizd-codex-runtime-init" >"$chown_expected"
  if [[ "$fail_at" -eq 2 ]]; then
    printf 'CALL\t%s\t%s\t%s\n' "$target_ownership" \
      "$chown_home/.zshenv" "$chown_home/.bashrc" >>"$chown_expected"
  fi
  cmp "$chown_expected" "$chown_log" >/dev/null || \
    die "narrow installer chowned paths outside its exact allowlist on call $fail_at"
done

# Runtime state must be made only from real directories owned by this user.
# In particular, the helper must reject every symlink before chmod/mkdir can
# follow it into a NAS-like target.
for runtime_slot in runtime-root codex codex-sqlite cache; do
  guarded_case="$tmp/guarded-symlink-$runtime_slot"
  guarded_runtime="$guarded_case/runtime"
  guarded_nas="$guarded_case/nas-target"
  mkdir -p "$guarded_case" "$guarded_nas"
  printf 'nas-must-not-change\n' >"$guarded_nas/sentinel"
  chmod 750 "$guarded_nas"

  if [[ "$runtime_slot" == runtime-root ]]; then
    ln -s "$guarded_nas" "$guarded_runtime"
  else
    mkdir -p "$guarded_runtime"
    ln -s "$guarded_nas" "$guarded_runtime/$runtime_slot"
  fi

  guarded_nas_listing="$(find "$guarded_nas" -print | LC_ALL=C sort)"
  guarded_nas_mode="$(mode_of "$guarded_nas")"
  if run_helper "$helper" "$home" "$nas" "$guarded_runtime"; then
    die "$runtime_slot runtime symlink was accepted"
  fi
  test "$(find "$guarded_nas" -print | LC_ALL=C sort)" = "$guarded_nas_listing" || \
    die "$runtime_slot runtime symlink caused a NAS mutation"
  test "$(mode_of "$guarded_nas")" = "$guarded_nas_mode" || \
    die "$runtime_slot runtime symlink changed the NAS directory mode"
  grep -Fx 'nas-must-not-change' "$guarded_nas/sentinel" >/dev/null || \
    die "$runtime_slot runtime symlink changed NAS content"
done

for runtime_slot in runtime-root codex codex-sqlite cache; do
  guarded_case="$tmp/guarded-file-$runtime_slot"
  guarded_runtime="$guarded_case/runtime"
  mkdir -p "$guarded_case"
  if [[ "$runtime_slot" == runtime-root ]]; then
    printf 'not-a-directory\n' >"$guarded_runtime"
  else
    mkdir -p "$guarded_runtime"
    printf 'not-a-directory\n' >"$guarded_runtime/$runtime_slot"
  fi

  if run_helper "$helper" "$home" "$nas" "$guarded_runtime"; then
    die "$runtime_slot non-directory runtime path was accepted"
  fi
done

# The Linux root fixture can create a genuine wrong-owner directory. This runs
# on hl_gpu_2; non-root local runs still cover type safety and mode tightening.
if [[ "$(id -u)" -eq 0 ]]; then
  for runtime_slot in runtime-root codex codex-sqlite cache; do
    guarded_case="$tmp/guarded-owner-$runtime_slot"
    guarded_runtime="$guarded_case/runtime"
    mkdir -p "$guarded_runtime/codex" "$guarded_runtime/codex-sqlite" \
      "$guarded_runtime/cache"
    if [[ "$runtime_slot" == runtime-root ]]; then
      chown 65534 "$guarded_runtime"
    else
      chown 65534 "$guarded_runtime/$runtime_slot"
    fi

    if run_helper "$helper" "$home" "$nas" "$guarded_runtime"; then
      die "$runtime_slot wrong-owner runtime directory was accepted"
    fi
  done
fi

mode_runtime="$tmp/mode-runtime"
mkdir -p "$mode_runtime/codex" "$mode_runtime/codex-sqlite" "$mode_runtime/cache"
chmod 777 "$mode_runtime" "$mode_runtime/codex" "$mode_runtime/codex-sqlite" \
  "$mode_runtime/cache"
run_helper "$helper" "$home" "$nas" "$mode_runtime"
for private_dir in "$mode_runtime" "$mode_runtime/codex" \
  "$mode_runtime/codex-sqlite" "$mode_runtime/cache"; do
  test "$(mode_of "$private_dir")" = 700 || \
    die "existing runtime directory was not tightened to 0700: $private_dir"
done

# Bare and quoted TOML keys are equivalent. Every supported sqlite_home key
# spelling must fail both installer-time and shell-time validation.
sqlite_key_spellings=(
  'sqlite_home'
  '"sqlite_home"'
  "'sqlite_home'"
)
sqlite_key_labels=(bare double-quoted single-quoted)
sqlite_index=0
for sqlite_key in "${sqlite_key_spellings[@]}"; do
  sqlite_label="${sqlite_key_labels[$sqlite_index]}"
  sqlite_nas="$tmp/sqlite-template-$sqlite_label/nas"
  make_shared_codex "$sqlite_nas"
  printf '%s = "/shared/unsafe.sqlite"\n' "$sqlite_key" >> \
    "$sqlite_nas/.agent-shared/codex/config.toml.template"

  sqlite_root="$tmp/sqlite-template-$sqlite_label/runtime"
  if run_helper "$helper" "$home" "$sqlite_nas" "$sqlite_root"; then
    die "a shared template containing $sqlite_label sqlite_home was accepted by the helper"
  fi
  test ! -e "$sqlite_root/codex/config.toml" || \
    die "$sqlite_label unsafe shared template produced a local config"
  if [[ -d "$sqlite_root/codex" ]] && \
    find "$sqlite_root/codex" -maxdepth 1 -name '.config.toml.tmp.*' -print | grep -q .; then
    die "$sqlite_label unsafe shared template left a temporary local config"
  fi

  sqlite_home="$tmp/sqlite-template-$sqlite_label/home"
  mkdir -p "$sqlite_home"
  if TARGET_USER="$(id -un)" TARGET_HOME="$sqlite_home" SHARED_HOME="$sqlite_nas" \
    LIZD_AGENT_RUNTIME_PARENT="$tmp/sqlite-template-$sqlite_label/installer-runtime" \
    INSTALL_SYSTEM_PACKAGES=0 INSTALL_NODE_TOOLS=0 CONFIGURE_CLAUDE_SHARING=0 \
    LIZD_ALLOW_NON_NFS_SHARED_HOME=1 "$sut" --install-codex-runtime-only; then
    die "a shared template containing $sqlite_label sqlite_home was accepted by the installer"
  fi
  test ! -e "$sqlite_home/.local/bin/lizd-codex-runtime-init" || \
    die "$sqlite_label unsafe shared template installed the runtime helper"

  sqlite_local_root="$tmp/sqlite-local-$sqlite_label/runtime"
  mkdir -p "$sqlite_local_root/codex"
  printf '%s = "/local/unsafe.sqlite"\n' "$sqlite_key" > \
    "$sqlite_local_root/codex/config.toml"
  cp "$sqlite_local_root/codex/config.toml" \
    "$tmp/sqlite-local-$sqlite_label-expected.toml"
  if run_helper "$helper" "$home" "$nas" "$sqlite_local_root"; then
    die "a local config containing $sqlite_label sqlite_home was accepted"
  fi
  cmp "$tmp/sqlite-local-$sqlite_label-expected.toml" \
    "$sqlite_local_root/codex/config.toml" >/dev/null || \
    die "$sqlite_label unsafe local config was modified"
  test ! -e "$sqlite_local_root/codex/.lizd-runtime-v1" || \
    die "$sqlite_label unsafe local config produced a runtime marker"

  sqlite_index=$((sqlite_index + 1))
done

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
