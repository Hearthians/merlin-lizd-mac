#!/usr/bin/env bash
# Fresh dev-machine bootstrap with minimal NAS usage.
#
# Shared on NAS:
#   - Codex auth.json, sessions, skills
#   - Claude Code auth/session/skill-like state
#   - zsh history
#
# Kept local per machine:
#   - HOME
#   - Codex config, logs, packages, SQLite state
#   - nvm, node, npm global packages, npm cache
#   - pip/user caches
#   - shell configs except history file target

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export CI=1
export NONINTERACTIVE=1

SHARED_HOME="${SHARED_HOME:-/mnt/bn/vai3d-hl-1/Users/lizd}"
TARGET_USER="${TARGET_USER:-${SUDO_USER:-${USER:-tiger}}}"
NODE_VERSION="${NODE_VERSION:-24}"
NVM_VERSION="${NVM_VERSION:-v0.40.3}"
INSTALL_SYSTEM_PACKAGES="${INSTALL_SYSTEM_PACKAGES:-1}"
INSTALL_NODE_TOOLS="${INSTALL_NODE_TOOLS:-1}"
CONFIGURE_CLAUDE_SHARING="${CONFIGURE_CLAUDE_SHARING:-1}"

if command -v getent >/dev/null 2>&1 && getent passwd "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_HOME="${TARGET_HOME:-$(getent passwd "$TARGET_USER" | cut -d: -f6)}"
else
  TARGET_HOME="${TARGET_HOME:-${HOME:-/home/$TARGET_USER}}"
fi

# Never default local runtime state to the NAS, even if HOME was poisoned by an
# older bootstrap script.
if [[ "$TARGET_HOME" == "$SHARED_HOME"* || "$TARGET_HOME" == /mnt/* ]]; then
  LOCAL_STATE_ROOT="${LOCAL_STATE_ROOT:-/tmp/${TARGET_USER}-agent-local}"
else
  LOCAL_STATE_ROOT="${LOCAL_STATE_ROOT:-$TARGET_HOME/.agent-local}"
fi

LIZD_AGENT_RUNTIME_PARENT="${LIZD_AGENT_RUNTIME_PARENT:-/tmp}"
CODEX_RUNTIME_DIRNAME="${CODEX_RUNTIME_DIRNAME:-lizd-agent-runtime-${TARGET_USER}}"
LIZD_AGENT_RUNTIME_ROOT="${LIZD_AGENT_RUNTIME_ROOT:-$LIZD_AGENT_RUNTIME_PARENT/$CODEX_RUNTIME_DIRNAME}"
LOCAL_CODEX_HOME="${LOCAL_CODEX_HOME:-$LIZD_AGENT_RUNTIME_ROOT/codex}"
LOCAL_CODEX_SQLITE_HOME="${LOCAL_CODEX_SQLITE_HOME:-$LIZD_AGENT_RUNTIME_ROOT/codex-sqlite}"
LOCAL_NVM_DIR="${LOCAL_NVM_DIR:-$LOCAL_STATE_ROOT/nvm}"

SHARED_AGENT_HOME="${SHARED_AGENT_HOME:-$SHARED_HOME/.agent-shared}"
SHARED_CODEX_HOME="${SHARED_CODEX_HOME:-$SHARED_AGENT_HOME/codex}"
SHARED_CODEX_CONFIG_TEMPLATE="${SHARED_CODEX_CONFIG_TEMPLATE:-$SHARED_CODEX_HOME/config.toml.template}"
SHARED_CLAUDE_HOME="${SHARED_CLAUDE_HOME:-$SHARED_AGENT_HOME/claude}"
SHARED_ZSH_HISTORY="${SHARED_ZSH_HISTORY:-$SHARED_HOME/.zsh_history}"

log() {
  printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

warn() {
  printf '\n\033[1;33m[WARN] %s\033[0m\n' "$*" >&2
}

die() {
  printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

verify_shared_home_mount() {
  if [[ "${LIZD_ALLOW_NON_NFS_SHARED_HOME:-0}" == "1" ]]; then
    return 0
  fi

  [[ -d "$SHARED_HOME" ]] || die "Shared home is unavailable: $SHARED_HOME"
  has_cmd findmnt || die "findmnt is required to verify the shared home mount"

  local fstype
  fstype="$(findmnt -n -T "$SHARED_HOME" -o FSTYPE 2>/dev/null || true)"
  case "$fstype" in
    nfs | nfs4) ;;
    *) die "Shared home is not on nfs/nfs4: $SHARED_HOME (${fstype:-unknown})" ;;
  esac
}

verify_shared_codex_inputs() {
  verify_shared_home_mount

  case "$SHARED_CODEX_HOME" in
    "$SHARED_HOME"/*) ;;
    *) die "Shared Codex home is outside SHARED_HOME: $SHARED_CODEX_HOME" ;;
  esac

  [[ -f "$SHARED_CODEX_HOME/auth.json" ]] || \
    die "Missing shared Codex auth file: $SHARED_CODEX_HOME/auth.json"
  [[ -d "$SHARED_CODEX_HOME/sessions" ]] || \
    die "Missing shared Codex sessions directory: $SHARED_CODEX_HOME/sessions"
  [[ -d "$SHARED_CODEX_HOME/skills" ]] || \
    die "Missing shared Codex skills directory: $SHARED_CODEX_HOME/skills"
  [[ -f "$SHARED_CODEX_CONFIG_TEMPLATE" ]] || \
    die "Missing shared Codex config template: $SHARED_CODEX_CONFIG_TEMPLATE"
  if grep -Eq '^[[:space:]]*sqlite_home[[:space:]]*=' "$SHARED_CODEX_CONFIG_TEMPLATE"; then
    die "Shared Codex config template must not set sqlite_home"
  fi
}

apt_has_pkg() {
  dpkg -s "$1" >/dev/null 2>&1
}

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

as_target_user() {
  local env_vars=(
    "HOME=$TARGET_HOME"
    "CODEX_HOME=$LOCAL_CODEX_HOME"
    "CODEX_SQLITE_HOME=$LOCAL_CODEX_SQLITE_HOME"
    "NVM_DIR=$LOCAL_NVM_DIR"
    "XDG_CACHE_HOME=$LOCAL_STATE_ROOT/cache"
    "PIP_CACHE_DIR=$LOCAL_STATE_ROOT/cache/pip"
    "PATH=$TARGET_HOME/.local/bin:$LOCAL_NVM_DIR/versions/node/v$NODE_VERSION/bin:$PATH"
  )

  if [[ "$(id -u)" -eq 0 ]] && id "$TARGET_USER" >/dev/null 2>&1; then
    if has_cmd runuser; then
      runuser -u "$TARGET_USER" -- env "${env_vars[@]}" "$@"
    elif has_cmd sudo; then
      sudo -H -u "$TARGET_USER" env "${env_vars[@]}" "$@"
    else
      warn "runuser/sudo not found; running as root with target env"
      env "${env_vars[@]}" "$@"
    fi
  else
    env "${env_vars[@]}" "$@"
  fi
}

chown_to_target() {
  if [[ "$(id -u)" -eq 0 ]] && id "$TARGET_USER" >/dev/null 2>&1; then
    local group
    group="$(id -gn "$TARGET_USER")"
    as_root chown "$TARGET_USER:$group" "$@" 2>/dev/null || true
  fi
}

link_shared_file() {
  local local_path="$1"
  local shared_path="$2"

  mkdir -p "$(dirname "$local_path")" "$(dirname "$shared_path")"

  if [[ -e "$local_path" && ! -L "$local_path" && ! -e "$shared_path" ]]; then
    cp -a "$local_path" "$shared_path"
  fi

  if [[ -e "$local_path" && ! -L "$local_path" ]]; then
    rm -f "$local_path"
  elif [[ -L "$local_path" ]]; then
    rm -f "$local_path"
  fi

  ln -s "$shared_path" "$local_path"
}

link_shared_dir() {
  local local_path="$1"
  local shared_path="$2"

  mkdir -p "$(dirname "$local_path")" "$shared_path"

  if [[ -d "$local_path" && ! -L "$local_path" ]]; then
    if [[ -z "$(find "$shared_path" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]]; then
      cp -a "$local_path"/. "$shared_path"/ 2>/dev/null || true
    fi
    rm -rf "$local_path"
  elif [[ -L "$local_path" ]]; then
    rm -f "$local_path"
  fi

  ln -s "$shared_path" "$local_path"
}

install_managed_block_atomic() {
  local file="$1"
  local name="$2"
  local body="$3"
  local dir tmp

  dir="$(dirname "$file")"
  mkdir -p "$dir"
  if [[ -e "$file" || -L "$file" ]]; then
    [[ -f "$file" && ! -L "$file" ]] || die "Refusing to replace shell config conflict: $file"
  fi

  tmp="$(mktemp "$dir/.lizd-shell-block.XXXXXX")" || die "Could not create shell config temporary file"
  if [[ -f "$file" ]]; then
    if ! awk -v start="# >>> $name" -v finish="# <<< $name" '
      $0 == start { managed = 1; next }
      managed && $0 == finish { managed = 0; next }
      !managed { print }
      END { if (managed) exit 42 }
    ' "$file" >"$tmp"; then
      rm -f "$tmp"
      die "Could not rewrite managed block in $file"
    fi
  else
    : >"$tmp"
  fi

  if ! {
    printf '\n# >>> %s\n' "$name"
    printf '%s\n' "$body"
    printf '# <<< %s\n' "$name"
  } >>"$tmp"; then
    rm -f "$tmp"
    die "Could not write managed block for $file"
  fi

  if ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    die "Could not atomically install managed block in $file"
  fi
}

install_codex_runtime_helper() {
  local helper="$TARGET_HOME/.local/bin/lizd-codex-runtime-init"
  local helper_tmp

  mkdir -p "$TARGET_HOME/.local/bin"
  helper_tmp="$(mktemp "$TARGET_HOME/.local/bin/.lizd-codex-runtime-init.XXXXXX")" || \
    die "Could not create runtime initializer temporary file"

  if ! cat >"$helper_tmp" <<'LIZD_CODEX_RUNTIME_INIT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() {
  printf 'lizd-codex-runtime-init: %s\n' "$*" >&2
  exit 1
}

[[ -n "${HOME:-}" ]] || fail "HOME is required"
[[ -n "${SHARED_HOME:-}" ]] || fail "SHARED_HOME is required"
[[ -n "${SHARED_CODEX_HOME:-}" ]] || fail "SHARED_CODEX_HOME is required"
[[ -n "${SHARED_CODEX_CONFIG_TEMPLATE:-}" ]] || fail "SHARED_CODEX_CONFIG_TEMPLATE is required"
[[ -n "${LIZD_AGENT_RUNTIME_ROOT:-}" ]] || fail "LIZD_AGENT_RUNTIME_ROOT is required"
[[ -n "${CODEX_HOME:-}" ]] || fail "CODEX_HOME is required"
[[ -n "${CODEX_SQLITE_HOME:-}" ]] || fail "CODEX_SQLITE_HOME is required"
[[ -n "${XDG_CACHE_HOME:-}" ]] || fail "XDG_CACHE_HOME is required"

for path in "$HOME" "$SHARED_HOME" "$SHARED_CODEX_HOME" \
  "$SHARED_CODEX_CONFIG_TEMPLATE" "$LIZD_AGENT_RUNTIME_ROOT" "$CODEX_HOME" \
  "$CODEX_SQLITE_HOME" "$XDG_CACHE_HOME"; do
  [[ "$path" == /* ]] || fail "required paths must be absolute: $path"
done

case "$SHARED_CODEX_HOME" in
  "$SHARED_HOME"/*) ;;
  *) fail "SHARED_CODEX_HOME must be below SHARED_HOME" ;;
esac
case "$SHARED_CODEX_CONFIG_TEMPLATE" in
  "$SHARED_CODEX_HOME"/*) ;;
  *) fail "SHARED_CODEX_CONFIG_TEMPLATE must be below SHARED_CODEX_HOME" ;;
esac
[[ "$CODEX_HOME" == "$LIZD_AGENT_RUNTIME_ROOT/codex" ]] || \
  fail "CODEX_HOME must be inside LIZD_AGENT_RUNTIME_ROOT"
[[ "$CODEX_SQLITE_HOME" == "$LIZD_AGENT_RUNTIME_ROOT/codex-sqlite" ]] || \
  fail "CODEX_SQLITE_HOME must be inside LIZD_AGENT_RUNTIME_ROOT"
[[ "$XDG_CACHE_HOME" == "$LIZD_AGENT_RUNTIME_ROOT/cache" ]] || \
  fail "XDG_CACHE_HOME must be inside LIZD_AGENT_RUNTIME_ROOT"

if [[ "${LIZD_ALLOW_NON_NFS_SHARED_HOME:-0}" != "1" ]]; then
  [[ -d "$SHARED_HOME" ]] || fail "shared home is unavailable: $SHARED_HOME"
  command -v findmnt >/dev/null 2>&1 || fail "findmnt is required to verify SHARED_HOME"
  shared_fstype="$(findmnt -n -T "$SHARED_HOME" -o FSTYPE 2>/dev/null || true)"
  case "$shared_fstype" in
    nfs | nfs4) ;;
    *) fail "SHARED_HOME is not on nfs/nfs4: $SHARED_HOME (${shared_fstype:-unknown})" ;;
  esac
fi

[[ -f "$SHARED_CODEX_HOME/auth.json" ]] || \
  fail "missing shared auth.json: $SHARED_CODEX_HOME/auth.json"
[[ -d "$SHARED_CODEX_HOME/sessions" ]] || \
  fail "missing shared sessions: $SHARED_CODEX_HOME/sessions"
[[ -d "$SHARED_CODEX_HOME/skills" ]] || \
  fail "missing shared skills: $SHARED_CODEX_HOME/skills"
[[ -f "$SHARED_CODEX_CONFIG_TEMPLATE" ]] || \
  fail "missing shared config template: $SHARED_CODEX_CONFIG_TEMPLATE"
if grep -Eq '^[[:space:]]*sqlite_home[[:space:]]*=' "$SHARED_CODEX_CONFIG_TEMPLATE"; then
  fail "shared config template must not set sqlite_home"
fi

mkdir -p "$LIZD_AGENT_RUNTIME_ROOT" || fail "could not create local runtime root"
lock_dir="$LIZD_AGENT_RUNTIME_ROOT/.lizd-codex-runtime-init.lock"
lock_attempt=0
until mkdir "$lock_dir" 2>/dev/null; do
  lock_attempt=$((lock_attempt + 1))
  [[ "$lock_attempt" -lt 200 ]] || fail "timed out waiting for runtime initialization lock"
  sleep 0.05
done

config_tmp=""
marker_tmp=""
cleanup() {
  [[ -z "$config_tmp" ]] || rm -f "$config_tmp"
  [[ -z "$marker_tmp" ]] || rm -f "$marker_tmp"
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir -p "$CODEX_HOME" "$CODEX_SQLITE_HOME" "$XDG_CACHE_HOME" || \
  fail "could not create local Codex runtime directories"

verify_link_slot() {
  local local_path="$1"
  local shared_path="$2"

  if [[ -L "$local_path" ]]; then
    [[ "$(readlink "$local_path")" == "$shared_path" ]] || \
      fail "unexpected symlink target at $local_path"
  elif [[ -e "$local_path" ]]; then
    fail "refusing to replace non-symlink path: $local_path"
  fi
}

ensure_link() {
  local local_path="$1"
  local shared_path="$2"

  [[ -L "$local_path" ]] || ln -s "$shared_path" "$local_path" || \
    fail "could not create symlink: $local_path"
}

verify_link_slot "$CODEX_HOME/auth.json" "$SHARED_CODEX_HOME/auth.json"
verify_link_slot "$CODEX_HOME/sessions" "$SHARED_CODEX_HOME/sessions"
verify_link_slot "$CODEX_HOME/skills" "$SHARED_CODEX_HOME/skills"

if [[ -e "$CODEX_HOME/config.toml" || -L "$CODEX_HOME/config.toml" ]]; then
  [[ -f "$CODEX_HOME/config.toml" && ! -L "$CODEX_HOME/config.toml" ]] || \
    fail "refusing local config conflict: $CODEX_HOME/config.toml"
  if grep -Eq '^[[:space:]]*sqlite_home[[:space:]]*=' "$CODEX_HOME/config.toml"; then
    fail "local config.toml must not set sqlite_home"
  fi
else
  config_tmp="$(mktemp "$CODEX_HOME/.config.toml.tmp.XXXXXX")" || \
    fail "could not create local config temporary file"
  if ! cp "$SHARED_CODEX_CONFIG_TEMPLATE" "$config_tmp"; then
    fail "could not copy shared config template"
  fi
  if ! mv "$config_tmp" "$CODEX_HOME/config.toml"; then
    fail "could not atomically install local config"
  fi
  config_tmp=""
fi

if [[ -e "$CODEX_HOME/.lizd-runtime-v1" || -L "$CODEX_HOME/.lizd-runtime-v1" ]]; then
  [[ -f "$CODEX_HOME/.lizd-runtime-v1" && ! -L "$CODEX_HOME/.lizd-runtime-v1" ]] || \
    fail "refusing runtime marker conflict"
fi

ensure_link "$CODEX_HOME/auth.json" "$SHARED_CODEX_HOME/auth.json"
ensure_link "$CODEX_HOME/sessions" "$SHARED_CODEX_HOME/sessions"
ensure_link "$CODEX_HOME/skills" "$SHARED_CODEX_HOME/skills"

marker_tmp="$(mktemp "$CODEX_HOME/.lizd-runtime-v1.tmp.XXXXXX")" || \
  fail "could not create runtime marker temporary file"
printf 'lizd-runtime-v1\n' >"$marker_tmp" || fail "could not write runtime marker"
if ! mv "$marker_tmp" "$CODEX_HOME/.lizd-runtime-v1"; then
  fail "could not atomically install runtime marker"
fi
marker_tmp=""
LIZD_CODEX_RUNTIME_INIT
  then
    rm -f "$helper_tmp"
    die "Could not write runtime initializer"
  fi

  if ! chmod 700 "$helper_tmp" || ! mv "$helper_tmp" "$helper"; then
    rm -f "$helper_tmp"
    die "Could not atomically install runtime initializer"
  fi
  chown_to_target "$helper"
}

install_codex_runtime_shell_blocks() {
  local body
  body="$(cat <<EOF
export LIZD_AGENT_RUNTIME_PARENT="\${LIZD_AGENT_RUNTIME_PARENT:-/tmp}"
export LIZD_AGENT_RUNTIME_ROOT="\$LIZD_AGENT_RUNTIME_PARENT/lizd-agent-runtime-\${USER:-tiger}"
export CODEX_HOME="\$LIZD_AGENT_RUNTIME_ROOT/codex"
export CODEX_SQLITE_HOME="\$LIZD_AGENT_RUNTIME_ROOT/codex-sqlite"
export XDG_CACHE_HOME="\$LIZD_AGENT_RUNTIME_ROOT/cache"
export SHARED_HOME="$SHARED_HOME"
export SHARED_CODEX_HOME="$SHARED_CODEX_HOME"
export SHARED_CODEX_CONFIG_TEMPLATE="$SHARED_CODEX_CONFIG_TEMPLATE"
if ! "\$HOME/.local/bin/lizd-codex-runtime-init"; then
  export CODEX_HOME=/dev/null
  export CODEX_SQLITE_HOME=/dev/null
fi
EOF
)"

  install_managed_block_atomic "$TARGET_HOME/.zshenv" \
    "minimal-nas-agents-codex-runtime" "$body"
  install_managed_block_atomic "$TARGET_HOME/.bashrc" \
    "minimal-nas-agents-codex-runtime" "$body"
  chown_to_target "$TARGET_HOME/.zshenv" "$TARGET_HOME/.bashrc"
}

install_codex_runtime() {
  log "Installing shell-time Codex runtime isolation"
  verify_shared_codex_inputs
  install_codex_runtime_helper
  install_codex_runtime_shell_blocks
}

install_system_packages() {
  [[ "$INSTALL_SYSTEM_PACKAGES" == "1" ]] || return 0

  log "Installing base system packages"

  local packages=(
    sudo
    zsh
    tmux
    git
    curl
    wget
    ca-certificates
    build-essential
    python3
    python3-pip
    python3-venv
    ripgrep
  )

  local missing=()
  local pkg
  for pkg in "${packages[@]}"; do
    apt_has_pkg "$pkg" || missing+=("$pkg")
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    as_root apt-get update -y
    as_root apt-get install -y --no-install-recommends "${missing[@]}"
  else
    log "Base packages already installed"
  fi
}

prepare_local_and_shared_dirs() {
  log "Preparing local runtime dirs and shared NAS dirs"

  mkdir -p \
    "$TARGET_HOME" \
    "$TARGET_HOME/.local/bin" \
    "$LOCAL_STATE_ROOT/cache/pip" \
    "$LOCAL_NVM_DIR" \
    "$(dirname "$SHARED_ZSH_HISTORY")"

  if [[ "$CONFIGURE_CLAUDE_SHARING" == "1" ]]; then
    mkdir -p "$SHARED_CLAUDE_HOME"
  fi

  touch "$SHARED_ZSH_HISTORY"

  chown_to_target \
    "$TARGET_HOME/.local" \
    "$TARGET_HOME/.local/bin" \
    "$LOCAL_STATE_ROOT" \
    "$LOCAL_STATE_ROOT/cache" \
    "$LOCAL_STATE_ROOT/cache/pip" \
    "$LOCAL_NVM_DIR" \
    "$SHARED_ZSH_HISTORY"
}

configure_codex_sharing() {
  install_codex_runtime
}

configure_claude_sharing() {
  log "Configuring Claude Code shared auth/session/skills state"

  local claude_dir="$TARGET_HOME/.claude"
  mkdir -p "$claude_dir" "$SHARED_CLAUDE_HOME"

  # Claude Code has used ~/.claude.json for account/config state. Keep it shared
  # so login follows the user across machines.
  link_shared_file "$TARGET_HOME/.claude.json" "$SHARED_CLAUDE_HOME/claude.json"

  # These names cover current and older layouts. Missing targets are harmless.
  link_shared_file "$claude_dir/auth.json" "$SHARED_CLAUDE_HOME/auth.json"
  link_shared_dir "$claude_dir/sessions" "$SHARED_CLAUDE_HOME/sessions"
  link_shared_dir "$claude_dir/projects" "$SHARED_CLAUDE_HOME/projects"
  link_shared_dir "$claude_dir/skills" "$SHARED_CLAUDE_HOME/skills"
  link_shared_dir "$claude_dir/agents" "$SHARED_CLAUDE_HOME/agents"

  chown_to_target "$claude_dir" "$TARGET_HOME/.claude.json" "$SHARED_CLAUDE_HOME"
}

configure_shells() {
  log "Configuring local shell env; only zsh history points to NAS"

  local zshenv="$TARGET_HOME/.zshenv"
  local zshrc="$TARGET_HOME/.zshrc"
  local bashrc="$TARGET_HOME/.bashrc"

  install_managed_block_atomic "$zshenv" "minimal-nas-agents-local-tools" "export NVM_DIR=\"$LOCAL_NVM_DIR\"
export PIP_CACHE_DIR=\"$LOCAL_STATE_ROOT/cache/pip\"
export PATH=\"\$HOME/.local/bin:\$NVM_DIR/versions/node/v$NODE_VERSION/bin:\$PATH\""

  install_managed_block_atomic "$zshrc" "minimal-nas-agents-local-tools" "export HISTFILE=\"$SHARED_ZSH_HISTORY\"
HISTSIZE=200000
SAVEHIST=200000
setopt APPEND_HISTORY INC_APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_REDUCE_BLANKS EXTENDED_HISTORY
[ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\""

  install_managed_block_atomic "$bashrc" "minimal-nas-agents-local-tools" "export NVM_DIR=\"$LOCAL_NVM_DIR\"
export PIP_CACHE_DIR=\"$LOCAL_STATE_ROOT/cache/pip\"
export PATH=\"\$HOME/.local/bin:\$NVM_DIR/versions/node/v$NODE_VERSION/bin:\$PATH\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\""

  chown_to_target "$zshenv" "$zshrc" "$bashrc"
}

install_node_tools_locally() {
  [[ "$INSTALL_NODE_TOOLS" == "1" ]] || return 0

  log "Installing nvm, Node.js $NODE_VERSION, Codex, and Claude Code locally"

  chown_to_target "$LOCAL_STATE_ROOT" "$LOCAL_NVM_DIR" "$TARGET_HOME/.local"

  as_target_user env NODE_VERSION="$NODE_VERSION" NVM_VERSION="$NVM_VERSION" bash -s <<'EOS'
set -Eeuo pipefail

mkdir -p "$NVM_DIR" "$XDG_CACHE_HOME"

if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | PROFILE=/dev/null bash
fi

# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"

if [[ "$(nvm version "$NODE_VERSION")" == "N/A" ]]; then
  nvm install "$NODE_VERSION" --no-progress
fi

nvm alias default "$NODE_VERSION"
nvm use "$NODE_VERSION"

npm config set fund false >/dev/null 2>&1 || true
npm config set audit false >/dev/null 2>&1 || true
npm config set cache "$XDG_CACHE_HOME/npm" >/dev/null 2>&1 || true

command -v codex >/dev/null 2>&1 || npm install -g @openai/codex@latest
command -v claude >/dev/null 2>&1 || npm install -g @anthropic-ai/claude-code@latest
EOS
}

print_summary() {
  log "Summary"
  printf 'Target user:             %s\n' "$TARGET_USER"
  printf 'Target home:             %s\n' "$TARGET_HOME"
  printf 'NAS shared root:         %s\n' "$SHARED_AGENT_HOME"
  printf 'Shared zsh history:      %s\n' "$SHARED_ZSH_HISTORY"
  printf 'Local runtime root:      %s\n' "$LIZD_AGENT_RUNTIME_ROOT"
  printf 'Local Codex home:        %s\n' "$LOCAL_CODEX_HOME"
  printf 'Local Codex SQLite home: %s\n' "$LOCAL_CODEX_SQLITE_HOME"
  printf '\nShared paths:\n'
  printf '  %s -> %s\n' "$LOCAL_CODEX_HOME/auth.json" "$SHARED_CODEX_HOME/auth.json"
  printf '  %s -> %s\n' "$LOCAL_CODEX_HOME/sessions" "$SHARED_CODEX_HOME/sessions"
  printf '  %s -> %s\n' "$LOCAL_CODEX_HOME/skills" "$SHARED_CODEX_HOME/skills"
  printf '  %s -> %s\n' "$TARGET_HOME/.claude.json" "$SHARED_CLAUDE_HOME/claude.json"
  printf '  %s -> %s\n' "$TARGET_HOME/.claude/projects" "$SHARED_CLAUDE_HOME/projects"
  printf '  %s -> %s\n' "$TARGET_HOME/.claude/skills" "$SHARED_CLAUDE_HOME/skills"
}

main() {
  if [[ "${1:-}" == "--install-codex-runtime-only" ]]; then
    [[ "$#" -eq 1 ]] || die "--install-codex-runtime-only accepts no additional arguments"
    install_codex_runtime
    return 0
  fi
  [[ "$#" -eq 0 ]] || die "Unknown argument: $1"

  verify_shared_home_mount
  install_system_packages
  prepare_local_and_shared_dirs
  configure_codex_sharing
  if [[ "$CONFIGURE_CLAUDE_SHARING" == "1" ]]; then
    configure_claude_sharing
  fi
  configure_shells
  install_node_tools_locally
  print_summary
}

main "$@"
