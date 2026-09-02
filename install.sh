#!/usr/bin/env bash
# Symlinks VS Code user config from this repo and installs extensions.
# Usage: ./install.sh [--no-ext] [--copy] [--profile NAME] [--role NAME | --groups a,b|all]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage="usage: $0 [--no-ext] [--copy] [--profile NAME] [--role NAME | --groups a,b|all]"

NO_EXT=0
COPY=0
ROLE=""
GROUPS_SET=0
PROFILE=""
EXT_GROUPS="core"
while [ "$#" -gt 0 ]; do
  case "$1" in
  --no-ext) NO_EXT=1 ;;
  --copy) COPY=1 ;;
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

# VS Code cannot create profiles from the CLI; make an existing one explicit.
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
Linux) USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User" ;;
Darwin) USER_DIR="$HOME/Library/Application Support/Code/User" ;;
MINGW* | MSYS* | CYGWIN*)
  USER_DIR="${APPDATA:-$HOME/AppData/Roaming}/Code/User"
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

if [ "$NO_EXT" -eq 0 ]; then
  if ! command -v code >/dev/null 2>&1; then
    echo "'code' CLI not found; no changes made." >&2
    echo "macOS: run 'Shell Command: Install code command in PATH' inside VS Code." >&2
    echo "Windows: reinstall VS Code with 'Add to PATH' enabled, or open a new shell." >&2
    exit 1
  fi
  if [ ! -f "$REPO_DIR/extensions.txt" ]; then
    echo "missing $REPO_DIR/extensions.txt" >&2
    exit 1
  fi
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

link_file settings.json

if [ "$NO_EXT" -eq 1 ]; then
  echo "skipped extensions (--no-ext)"
  exit 0
fi

# Prints the ids under one [group], or every id when passed "all".
list_group() {
  awk -v want="$1" '
    {
      sub(/#.*/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")
    }
    /^\[.*\]$/ {
      group = substr($0, 2, length($0) - 2)
      next
    }
    $0 != "" && (want == "all" || group == want) { print }
  ' "$REPO_DIR/extensions.txt"
}

exts=""
# set -f: a group list must never glob against files in the working directory.
set -f
for group in $(echo "$EXT_GROUPS" | tr ',' ' '); do
  found="$(list_group "$group")"
  if [ -z "$found" ]; then
    echo "unknown or empty group: $group" >&2
    exit 2
  fi
  exts="$exts$found
"
done
set +f
# Overlapping groups (e.g. "all,core") must not install twice.
exts="$(printf '%s' "$exts" | awk '!seen[$0]++')"

# The heredoc keeps the loop out of a subshell so the counter survives.
failed=0
while read -r ext; do
  [ -n "$ext" ] || continue
  run_code --install-extension "$ext" </dev/null || {
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
