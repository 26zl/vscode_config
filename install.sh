#!/usr/bin/env bash
# Symlinks VS Code user config from this repo and installs extensions, from the
# Marketplace or, without internet, from a VSIX bundle built by --download.
# Usage: ./install.sh [--no-ext] [--copy] [--profile NAME] [--role NAME | --groups a,b|all]
#        ./install.sh --download [--platform P] [--code-version V] [--role NAME | --groups a,b|all]
#        ./install.sh --offline [--copy] [--profile NAME]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage="usage: $0 [--no-ext] [--copy] [--profile NAME] [--role NAME | --groups a,b|all]
       $0 --download [--platform P] [--code-version V] [--role NAME | --groups a,b|all]
       $0 --offline [--copy] [--profile NAME]"

# True for VS Code 1.125 or newer.
new_enough() {
  printf '%s\n' "$1" | awk -F. '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && ($1 > 1 || ($1 == 1 && $2 >= 125)) { valid = 1 } END { exit !valid }'
}

NO_EXT=0
COPY=0
DOWNLOAD=0
OFFLINE=0
ROLE=""
GROUPS_SET=0
PROFILE=""
PLATFORM=""
TARGET_VERSION=""
EXT_GROUPS="core"
while [ "$#" -gt 0 ]; do
  case "$1" in
  --no-ext) NO_EXT=1 ;;
  --copy) COPY=1 ;;
  --download) DOWNLOAD=1 ;;
  --offline) OFFLINE=1 ;;
  --platform)
    shift
    PLATFORM="${1:-}"
    case "$PLATFORM" in
    "" | *[!a-z0-9-]*)
      echo "--platform needs a VS Code target such as linux-x64, darwin-arm64 or win32-x64" >&2
      exit 2
      ;;
    esac
    ;;
  --code-version)
    shift
    TARGET_VERSION="${1:-}"
    if ! new_enough "$TARGET_VERSION"; then
      echo "--code-version needs VS Code 1.125 or newer, e.g. 1.139.0" >&2
      exit 2
    fi
    ;;
  --profile)
    shift
    PROFILE="${1:-}"
    if [ -z "$PROFILE" ]; then
      echo "--profile needs a name" >&2
      exit 2
    fi
    ;;
  --groups)
    shift
    EXT_GROUPS="${1:-}"
    GROUPS_SET=1
    if [ -z "$EXT_GROUPS" ]; then
      echo "--groups needs a list, e.g. core,k8s or all" >&2
      exit 2
    fi
    ;;
  --role)
    shift
    ROLE="${1:-}"
    if [ -z "$ROLE" ]; then
      echo "--role needs a name: sysadmin, cybersec or fullstack" >&2
      exit 2
    fi
    ;;
  -h | --help)
    echo "$usage"
    exit 0
    ;;
  *)
    echo "$usage" >&2
    exit 2
    ;;
  esac
  shift
done

if [ "$DOWNLOAD" -eq 1 ] && { [ "$OFFLINE" -eq 1 ] || [ "$NO_EXT" -eq 1 ]; }; then
  echo "--download cannot be combined with --offline or --no-ext" >&2
  exit 2
fi
if [ "$OFFLINE" -eq 1 ] && { [ -n "$ROLE" ] || [ "$GROUPS_SET" -eq 1 ]; }; then
  echo "--offline installs the whole bundle; pick groups with --download" >&2
  exit 2
fi
if [ "$DOWNLOAD" -eq 0 ] && { [ -n "$PLATFORM" ] || [ -n "$TARGET_VERSION" ]; }; then
  echo "--platform and --code-version only apply to --download" >&2
  exit 2
fi

# Extension installation accepts only existing profiles.
run_code() {
  if [ -n "$PROFILE" ]; then
    code --profile "$PROFILE" "$@"
  else
    code "$@"
  fi
}

# Named roles are complete, ready-made group bundles.
if [ -n "$ROLE" ]; then
  if [ "$GROUPS_SET" -eq 1 ]; then
    echo "use --role or --groups, not both" >&2
    exit 2
  fi
  case "$ROLE" in
  sysadmin) EXT_GROUPS="core,k8s,ops" ;;
  cybersec) EXT_GROUPS="core,k8s,ops,security" ;;
  fullstack) EXT_GROUPS="core,fullstack,ops" ;;
  *)
    echo "unknown role: $ROLE (sysadmin, cybersec, fullstack)" >&2
    exit 2
    ;;
  esac
fi

OS="$(uname -s)"
case "$OS" in
Linux)
  USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User"
  CODE_OS=linux
  ;;
Darwin)
  USER_DIR="$HOME/Library/Application Support/Code/User"
  CODE_OS=darwin
  ;;
MINGW* | MSYS* | CYGWIN*)
  USER_DIR="${APPDATA:-$HOME/AppData/Roaming}/Code/User"
  CODE_OS=win32
  # Git Bash otherwise copies the file and still calls it a link, which would
  # detach the config from this repo without saying so. nativestrict turns that
  # into a hard error, caught by the preflight below.
  export MSYS=winsymlinks:nativestrict
  ;;
*)
  echo "unsupported OS: $OS" >&2
  exit 1
  ;;
esac

# Every role also takes the Windows-only group when the target is Windows,
# a --download bundle for it included; on Linux and macOS that group would
# fail the run, so --groups leaves the choice explicit.
target_os="$CODE_OS"
[ -n "$PLATFORM" ] && target_os="${PLATFORM%%-*}"
if [ -n "$ROLE" ] && [ "$target_os" = win32 ]; then
  EXT_GROUPS="$EXT_GROUPS,windows"
fi

# Prints the ids under one [group], or every id when passed "all"; "all" only
# takes the Windows-only group when the target is Windows.
list_group() {
  awk -v want="$1" -v win="$([ "$target_os" = win32 ] && echo 1 || echo 0)" '
    {
      sub(/#.*/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")
    }
    /^\[.*\]$/ {
      group = substr($0, 2, length($0) - 2)
      next
    }
    $0 != "" && (group == want || (want == "all" && (group != "windows" || win == 1))) { print }
  ' "$REPO_DIR/extensions.txt"
}

# VSIX installs skip VS Code's own signature check, so every package is first
# verified with the vsce-sign binary VS Code ships for that check.
verify_bundle() {
  app="$(code --locate-shell-integration-path bash 2>/dev/null || true)"
  sign="${VSCE_SIGN:-${app%[\\/]out[\\/]vs[\\/]*}/node_modules.asar.unpacked/@vscode/vsce-sign/bin/vsce-sign}"
  [ -f "$sign" ] || sign="$sign.exe"
  if [ ! -f "$sign" ]; then
    echo "cannot find VS Code's vsce-sign; set VSCE_SIGN to its path. No changes made." >&2
    exit 1
  fi
  for vsix in "$1"/*.vsix; do
    if ! "$sign" verify --package "$vsix" --signaturearchive "${vsix%.vsix}.sigzip" >/dev/null 2>&1; then
      echo "invalid Marketplace signature: $vsix" >&2
      exit 1
    fi
  done
}

if [ "$NO_EXT" -eq 0 ]; then
  if ! command -v code >/dev/null 2>&1; then
    echo "'code' CLI not found; no changes made." >&2
    echo "macOS: run 'Shell Command: Install code command in PATH' inside VS Code." >&2
    echo "Windows: reinstall VS Code with 'Add to PATH' enabled, or open a new shell." >&2
    exit 1
  fi
  # Captured so a CLI that fails for another reason is not called outdated.
  # On a fresh WSL distro or SSH host the remote wrapper first prints
  # "Installing VS Code Server ..." lines, so start at the version line.
  code_info="$(code --version 2>/dev/null | sed -n '/^[0-9][0-9]*\.[0-9][0-9]*\.[0-9]/,$p' || true)"
  code_version="$(printf '%s\n' "$code_info" | sed -n 1p)"
  if ! new_enough "$code_version"; then
    echo "VS Code 1.125 or newer is required, got '$code_version'; no changes made." >&2
    exit 1
  fi
  # The Marketplace name for this build, e.g. linux-x64 or darwin-arm64.
  platform="$CODE_OS-$(printf '%s\n' "$code_info" | sed -n 3p)"
  if [ ! -f "$REPO_DIR/extensions.txt" ]; then
    echo "missing $REPO_DIR/extensions.txt" >&2
    exit 1
  fi
  exts=""
  # set -f: a group list must never glob against files in the working directory.
  set -f
  for group in $(echo "$EXT_GROUPS" | tr ',' ' '); do
    found="$(list_group "$group")"
    if [ -z "$found" ]; then
      echo "unknown or empty group: $group; no changes made." >&2
      exit 2
    fi
    exts="$exts$found
"
  done
  set +f
  # Overlapping groups (e.g. "all,core") must not install twice.
  exts="$(printf '%s' "$exts" | awk '!seen[$0]++')"
  if [ "$OFFLINE" -eq 1 ]; then
    bundle="$REPO_DIR/vsix/$platform"
    if ! compgen -G "$bundle/*.vsix" >/dev/null; then
      echo "no VSIX bundle in $bundle; build it with ./install.sh --download; no changes made." >&2
      exit 1
    fi
    verify_bundle "$bundle"
    exts="$(printf '%s\n' "$bundle"/*.vsix)"
  fi
  if [ -n "$PROFILE" ] && ! run_code --list-extensions >/dev/null; then
    echo "cannot use VS Code profile '$PROFILE'; no changes made." >&2
    exit 1
  fi
fi

if [ "$DOWNLOAD" -eq 1 ]; then
  platform="${PLATFORM:-$platform}"
  bundle="$REPO_DIR/vsix/$platform"
  set -f
  # shellcheck disable=SC2086  # one argument per extension id
  bash "$REPO_DIR/download-vsix.sh" "$bundle" "$platform" "${TARGET_VERSION:-$code_version}" $exts
  set +f
  verify_bundle "$bundle"
  echo "ready: $bundle; copy this folder to the offline machine and run ./install.sh --offline"
  exit 0
fi

mkdir -p "$USER_DIR"

# Fail before touching the user config when symlinks are unavailable — on
# Windows they need Developer Mode or an elevated shell.
if [ "$COPY" -eq 0 ]; then
  probe="$USER_DIR/.symlink-probe.$$"
  rm -f "$probe"
  if ! ln -sfn symlink-probe-target "$probe" 2>/dev/null || [ ! -L "$probe" ]; then
    rm -f "$probe"
    echo "cannot create symlinks in $USER_DIR; no changes made." >&2
    case "$OS" in
    MINGW* | MSYS* | CYGWIN*)
      echo "Windows grants that only with Developer Mode on (Settings -> System ->" >&2
      echo "For developers) or in an elevated shell. Enable it and rerun, or use" >&2
      echo "./install.sh --copy to copy the file instead." >&2
      ;;
    esac
    exit 1
  fi
  rm -f "$probe"
fi

link_file() {
  src="$REPO_DIR/$1"
  dst="$USER_DIR/$1"
  # Real files are backed up, never overwritten; old symlinks are replaced.
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    backup="$dst.backup.$(date +%Y%m%d-%H%M%S)"
    while [ -e "$backup" ]; do
      backup="$backup.1"
    done
    mv "$dst" "$backup"
    echo "backed up: $dst -> $backup"
  fi
  if [ "$COPY" -eq 1 ]; then
    # A copy does not track the repo; every update needs this command again.
    rm -f "$dst"
    cp "$src" "$dst"
    echo "copied: $src -> $dst (rerun after every repo update)"
    return
  fi
  ln -sfn "$src" "$dst"
  echo "linked: $dst -> $src"
}

# Commits from this clone leave out the keys extensions write into the linked
# file; a copy outside Git, or nested in another repo, skips this.
if command -v git >/dev/null 2>&1 && [ -z "$(git -C "$REPO_DIR" rev-parse --show-prefix 2>/dev/null || echo outside)" ]; then
  git -C "$REPO_DIR" config filter.vscode-settings.clean 'bash ./clean-settings.sh --filter'
fi

link_file settings.json

if [ "$NO_EXT" -eq 1 ]; then
  echo "skipped extensions (--no-ext)"
  exit 0
fi

install_one() {
  if [ "$OFFLINE" -eq 1 ]; then
    # The bundle carries every dependency; this CLI flag, missing from --help,
    # keeps VS Code from looking them up in the Marketplace.
    run_code --install-extension "$1" --do-not-include-pack-dependencies
  else
    run_code --install-extension "$1"
  fi
}

# The heredoc keeps the loop out of a subshell so the counter survives.
failed=0
while read -r ext; do
  [ -n "$ext" ] || continue
  install_one "$ext" </dev/null || {
    echo "warning: failed to install $ext" >&2
    failed=$((failed + 1))
  }
done <<EOF
$exts
EOF

if [ "$failed" -gt 0 ]; then
  echo "done, but $failed extension(s) failed to install" >&2
  exit 1
fi
echo "done"
