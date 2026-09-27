#!/usr/bin/env bash
# Unpins every activity bar icon and bottom panel tab that a sysadmin does not
# need, exactly as right-click -> untick would, and hides the Accounts menu,
# the sign-in and Settings Sync entry point. That is UI state in VS Code's
# state.vscdb, not a setting, so settings.json cannot carry it. Run it with
# VS Code closed: VS Code writes that database on exit and would undo the
# change. The lists to keep are at the top of the Python program.
# Usage: ./clean-activitybar.sh [--dry-run]
# VSCODE_STATE_DB points it at another database (Insiders, a test); the
# running-VS-Code check then stays with the caller.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

DRY_RUN=0
case "${1:-}" in
"") ;;
--dry-run) DRY_RUN=1 ;;
*)
  echo "usage: $0 [--dry-run]" >&2
  exit 2
  ;;
esac

# shellcheck source=find-python.sh
. ./find-python.sh
if [ -z "$PYTHON" ]; then
  echo "no Python 3 found (tried python3, python, py -3)" >&2
  exit 1
fi

code_running() {
  case "$(uname -s)" in
  Darwin) pgrep -f '/Visual Studio Code.app/Contents/MacOS/Electron' >/dev/null ;;
  MINGW* | MSYS* | CYGWIN*) tasklist 2>/dev/null | grep -qi '^Code\.exe' ;;
  *) pgrep -x code >/dev/null ;;
  esac
}

if [ -n "${VSCODE_STATE_DB:-}" ]; then
  db="$VSCODE_STATE_DB"
else
  # WSL looks like Linux, but the VS Code that draws the bar runs on Windows
  # and keeps its state there.
  if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
    echo "inside WSL; VS Code keeps its UI state on Windows, so run this from Git Bash there. No changes made." >&2
    exit 1
  fi
  case "$(uname -s)" in
  Linux) user_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User" ;;
  Darwin) user_dir="$HOME/Library/Application Support/Code/User" ;;
  MINGW* | MSYS* | CYGWIN*) user_dir="${APPDATA:-$HOME/AppData/Roaming}/Code/User" ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
  esac
  db="$user_dir/globalStorage/state.vscdb"
  if [ "$DRY_RUN" -eq 0 ] && code_running; then
    echo "VS Code is running and would overwrite the change on exit; close it and rerun. No changes made." >&2
    exit 1
  fi
fi

"$PYTHON" - "$db" "$DRY_RUN" <<'PY'
import json
import sqlite3
import sys
import time
from pathlib import Path

# Containers that stay visible. Everything else in the bar is unpinned, so a
# newly installed extension is hidden on the next run too. The ids come from
# the extension's package.json (contributes.viewsContainers) with the prefix
# VS Code adds; built-in ones are listed in the workbench.
KEEP = {
    # Activity bar: right-click on it shows the same list by name.
    "workbench.activity.pinnedViewlets2": {
        "workbench.view.explorer",
        "workbench.view.search",
        "workbench.view.scm",
        "workbench.view.extensions",
        # Remote-SSH and WSL targets.
        "workbench.view.remote",
        "workbench.view.extension.kubernetesView",
        "workbench.view.extension.containersView",
        # [ai] group; stays hidden-by-absence when Claude Code is not installed.
        "workbench.view.extension.claude-sidebar",
    },
    # Bottom panel tabs.
    "workbench.panel.pinnedPanels": {
        "workbench.panel.markers",  # Problems
        "workbench.panel.output",
        "terminal",
        "~remote.forwardedPortsContainer",  # Ports
        # Shown by the refactor preview itself; unpinning would only confuse it.
        "refactorPreview",
    },
}

# The Accounts menu at the bottom of the bar: the sign-in and Settings Sync
# entry point. Right-click -> Accounts brings it back.
ACCOUNTS_KEY = "workbench.activity.showAccounts"

db = Path(sys.argv[1])
dry_run = sys.argv[2] == "1"
if not db.is_file():
    raise SystemExit(f"no VS Code state database at {db}; start VS Code once first. No changes made.")

conn = sqlite3.connect(db)
try:
    updates, changes = {}, []
    for key, keep in KEEP.items():
        label = "activity bar" if key.endswith("pinnedViewlets2") else "panel"
        row = conn.execute("SELECT value FROM ItemTable WHERE key = ?", (key,)).fetchone()
        if row is None:
            # VS Code writes the key once the bar has been touched or on exit.
            continue
        try:
            items = json.loads(row[0])
        except (TypeError, ValueError):
            items = None
        if not isinstance(items, list) or any(
            not isinstance(item, dict) or "id" not in item or "pinned" not in item for item in items
        ):
            raise SystemExit(f"unexpected layout under {key}; this VS Code release stores the bar differently. No changes made.")
        for item in items:
            want = item["id"] in keep
            if item["pinned"] != want:
                changes.append((label, item["id"], want))
                item["pinned"] = want
        updates[key] = json.dumps(items, separators=(",", ":"))
    row = conn.execute("SELECT value FROM ItemTable WHERE key = ?", (ACCOUNTS_KEY,)).fetchone()
    if row is None or row[0] != "false":
        changes.append(("activity bar", "accounts menu", False))
        updates[ACCOUNTS_KEY] = "false"
except sqlite3.DatabaseError as error:
    raise SystemExit(f"cannot read {db}: {error}. No changes made.")

if not changes:
    print("activity bar and panel already clean")
    raise SystemExit
for label, item_id, want in changes:
    print(f"{'show' if want else 'hide'} {label}: {item_id}")
if dry_run:
    print(f"dry run: {len(changes)} change(s) not written")
    raise SystemExit

# The SQLite backup API copies a consistent snapshot even with a WAL file.
backup = db.with_name(f"{db.name}.backup.{time.strftime('%Y%m%d-%H%M%S')}")
while backup.exists():
    backup = backup.with_name(backup.name + ".1")
with sqlite3.connect(backup) as copy:
    conn.backup(copy)
with conn:
    for key, value in updates.items():
        conn.execute("INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)", (key, value))
conn.close()
print(f"wrote {len(changes)} change(s); backup: {backup}")
PY
