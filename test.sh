#!/usr/bin/env bash
# Repo self-check: settings parse, extension ids look sane, install.sh works.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# shellcheck source=find-python.sh
. ./find-python.sh
if [ -z "$PYTHON" ]; then
  echo "no Python 3 found (tried python3, python, py -3)" >&2
  exit 1
fi

# settings.json must be valid JSON with unique keys once full-line // comments
# are stripped. Keep comments full-line so this check stays reliable.
"$PYTHON" - <<'PY'
import json
import re

def no_dupes(pairs):
    keys = [key for key, _ in pairs]
    dupes = sorted({key for key in keys if keys.count(key) > 1})
    if dupes:
        raise SystemExit(f"fail: duplicate keys: {dupes}")
    return dict(pairs)

raw = open("settings.json", encoding="utf-8").read()
stripped = re.sub(r"^[ \t]*//.*$", "", raw, flags=re.M)
json.loads(stripped, object_pairs_hook=no_dupes)
print("ok: settings.json parses, keys unique")
PY

if [ ! -f extensions.txt ]; then
  echo "fail: extensions.txt missing" >&2
  exit 1
fi

# Extension ids must look like publisher.name.
sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' extensions.txt |
  sed -e '/^$/d' -e '/^\[.*\]$/d' |
  while read -r ext; do
    case "$ext" in
    *.*) ;;
    *)
      echo "fail: bad extension id: $ext" >&2
      exit 1
      ;;
    esac
  done
echo "ok: extensions.txt ids"

# Every publisher in extensions.txt must be allow-listed, or VS Code refuses
# to install it.
"$PYTHON" - <<'PY'
import json
import re

raw = open("settings.json", encoding="utf-8").read()
allowed = json.loads(re.sub(r"^[ \t]*//.*$", "", raw, flags=re.M))["extensions.allowed"]

publishers = set()
for line in open("extensions.txt", encoding="utf-8"):
    line = line.split("#", 1)[0].strip()
    if line and not line.startswith("[") and "." in line:
        publishers.add(line.split(".", 1)[0])

blocked = sorted(p for p in publishers if p not in allowed)
if blocked:
    raise SystemExit(f"fail: publishers missing from extensions.allowed: {blocked}")

# VS Code resolves Microsoft-published extensions against the org key
# "microsoft" instead of their ms-* publisher ids.
if any(p.startswith("ms-") for p in publishers) and allowed.get("microsoft") is not True:
    raise SystemExit('fail: ms-* publishers require "microsoft": true in extensions.allowed')
print("ok: every publisher is allow-listed")
PY

# install.sh must link settings into a sandbox HOME (never the real config)
# and back up a pre-existing real file instead of overwriting it.
repo_dir="$PWD"
tmp_home="$(mktemp -d)"
trap 'rm -rf "$tmp_home"' EXIT

# Mirrors the user-directory layout install.sh picks per platform.
user_dir_for() {
  case "$(uname -s)" in
  Darwin) echo "$1/Library/Application Support/Code/User" ;;
  MINGW* | MSYS* | CYGWIN*) echo "$1/AppData/Roaming/Code/User" ;;
  *) echo "$1/.config/Code/User" ;;
  esac
}

# Runs install.sh against a sandbox home, never the real user config.
run_install() {
  sandbox="$1"
  shift
  HOME="$sandbox" APPDATA="$sandbox/AppData/Roaming" XDG_CONFIG_HOME='' ./install.sh "$@"
}

user_dir="$(user_dir_for "$tmp_home")"
mkdir -p "$user_dir"
echo '{"existing": true}' >"$user_dir/settings.json"
run_install "$tmp_home" --no-ext >/dev/null
if [ ! -L "$user_dir/settings.json" ]; then
  echo "fail: settings.json not linked" >&2
  exit 1
fi
if ! compgen -G "$user_dir/settings.json.backup.*" >/dev/null; then
  echo "fail: pre-existing settings.json was not backed up" >&2
  exit 1
fi
echo "ok: install.sh links settings and backs up existing file"

if ! run_install "$tmp_home" --help >/dev/null; then
  echo "fail: install.sh --help must exit 0" >&2
  exit 1
fi
echo "ok: install.sh --help"

fake_bin="$tmp_home/bin"
mkdir -p "$fake_bin"
# Wrappers, not copies: on Windows "ln -s" copies the .exe without its suffix
# or its DLLs, so the stub cannot run and install.sh would die for a reason
# these tests are not looking for.
for tool in dirname uname mkdir ln; do
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v "$tool")" >"$fake_bin/$tool"
  chmod +x "$fake_bin/$tool"
done
missing_home="$tmp_home/missing-code-home"
if PATH="$fake_bin" HOME="$missing_home" APPDATA="$missing_home/AppData/Roaming" XDG_CONFIG_HOME='' /bin/bash ./install.sh >/dev/null 2>&1; then
  echo "fail: install.sh succeeded without the code CLI" >&2
  exit 1
fi
if [ -e "$missing_home" ]; then
  echo "fail: install.sh changed HOME before the code CLI preflight failed" >&2
  exit 1
fi
echo "ok: install.sh reports a missing code CLI"

cat >"$fake_bin/code" <<'SH'
#!/usr/bin/env sh
exit 1
SH
chmod +x "$fake_bin/code"
if PATH="$fake_bin:$PATH" HOME="$tmp_home" APPDATA="$tmp_home/AppData/Roaming" XDG_CONFIG_HOME='' ./install.sh >/dev/null 2>&1; then
  echo "fail: install.sh succeeded after extension install failure" >&2
  exit 1
fi
echo "ok: install.sh reports extension install failures"

# A role must expand to exactly its documented groups, and unknown roles fail.
cat >"$fake_bin/code" <<'SH'
#!/usr/bin/env sh
echo "$@"
SH
role_out="$(PATH="$fake_bin:$PATH" run_install "$tmp_home" --role sysadmin 2>/dev/null | grep -- --install-extension | sort)"
groups_out="$(PATH="$fake_bin:$PATH" run_install "$tmp_home" --groups core,k8s,ops 2>/dev/null | grep -- --install-extension | sort)"
if [ -z "$role_out" ] || [ "$role_out" != "$groups_out" ]; then
  echo "fail: --role sysadmin does not match --groups core,k8s,ops" >&2
  exit 1
fi
if PATH="$fake_bin:$PATH" run_install "$tmp_home" --role tull >/dev/null 2>&1; then
  echo "fail: unknown role accepted" >&2
  exit 1
fi
if PATH="$fake_bin:$PATH" run_install "$tmp_home" --role sysadmin --groups ops >/dev/null 2>&1; then
  echo "fail: --role and --groups accepted together" >&2
  exit 1
fi
echo "ok: roles expand to their groups"

# --copy is the fallback for machines that cannot create symlinks; it must
# write a real file and still back up what was there.
copy_home="$tmp_home/copy-home"
copy_dir="$(user_dir_for "$copy_home")"
mkdir -p "$copy_dir"
echo '{"existing": true}' >"$copy_dir/settings.json"
run_install "$copy_home" --no-ext --copy >/dev/null
if [ -L "$copy_dir/settings.json" ] || [ ! -f "$copy_dir/settings.json" ]; then
  echo "fail: --copy did not write a real file" >&2
  exit 1
fi
if ! cmp -s settings.json "$copy_dir/settings.json"; then
  echo "fail: --copy did not reproduce settings.json" >&2
  exit 1
fi
if ! compgen -G "$copy_dir/settings.json.backup.*" >/dev/null; then
  echo "fail: --copy did not back up the existing file" >&2
  exit 1
fi
echo "ok: install.sh --copy writes a real file and backs up"

# Without symlink permission (Windows without Developer Mode), install.sh must
# stop at the preflight and leave the existing settings untouched.
noln_bin="$tmp_home/noln-bin"
noln_home="$tmp_home/noln-home"
noln_dir="$(user_dir_for "$noln_home")"
mkdir -p "$noln_bin" "$noln_dir"
cat >"$noln_bin/ln" <<'SH'
#!/usr/bin/env sh
exit 1
SH
chmod +x "$noln_bin/ln"
echo '{"existing": true}' >"$noln_dir/settings.json"
if PATH="$noln_bin:$PATH" run_install "$noln_home" --no-ext >/dev/null 2>&1; then
  echo "fail: install.sh succeeded without symlink support" >&2
  exit 1
fi
if [ "$(cat "$noln_dir/settings.json")" != '{"existing": true}' ]; then
  echo "fail: install.sh touched settings.json after the symlink preflight failed" >&2
  exit 1
fi
if compgen -G "$noln_dir/settings.json.backup.*" >/dev/null; then
  echo "fail: install.sh backed up settings.json before the preflight failed" >&2
  exit 1
fi
echo "ok: install.sh stops when symlinks are unavailable"

# bootstrap.sh must use the interpreter layout this platform creates:
# .venv/Scripts/python.exe on Windows, .venv/bin/python everywhere else.
boot_dir="$tmp_home/bootstrap"
mkdir -p "$boot_dir/bin"
"$PYTHON" -m venv --without-pip "$boot_dir/.venv" >/dev/null
cat >"$boot_dir/bin/uv" <<'SH'
#!/usr/bin/env sh
# Records what bootstrap.sh resolved instead of installing anything.
echo "$@" >>"$UV_CALLS"
SH
chmod +x "$boot_dir/bin/uv"
(
  cd "$boot_dir" || exit 1
  export PATH="$boot_dir/bin:$PATH" UV_CALLS="$boot_dir/uv-calls"
  bash "$repo_dir/bootstrap.sh" python >/dev/null
)
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) want_python=".venv/Scripts/python.exe" ;;
*) want_python=".venv/bin/python" ;;
esac
if ! grep -qF -- "--python $want_python " "$boot_dir/uv-calls"; then
  echo "fail: bootstrap.sh did not install into $want_python" >&2
  cat "$boot_dir/uv-calls" >&2
  exit 1
fi
echo "ok: bootstrap.sh targets this platform's venv layout"

# Without uv, bootstrap.sh must fall back to pip inside that same venv; a stub
# pip module records the call instead of installing anything. PATH holds only
# the two commands bootstrap.sh needs, so nothing on it may rely on PATH itself.
site="$("$boot_dir/$want_python" -c 'import pathlib, sysconfig; print(pathlib.Path(sysconfig.get_paths()["purelib"]).as_posix())')"
mkdir -p "$site/pip"
: >"$site/pip/__init__.py"
cat >"$site/pip/__main__.py" <<'PY'
import os
import sys

with open(os.environ["PIP_CALLS"], "a", encoding="utf-8") as calls:
    calls.write(" ".join(sys.argv[1:]) + "\n")
PY
nouv_bin="$boot_dir/nouv"
mkdir -p "$nouv_bin"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v "$PYTHON")" >"$nouv_bin/python3"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v dirname)" >"$nouv_bin/dirname"
chmod +x "$nouv_bin/python3" "$nouv_bin/dirname"
bash_bin="$(command -v bash)"
(
  cd "$boot_dir" || exit 1
  PATH="$nouv_bin" PIP_CALLS="$boot_dir/pip-calls" "$bash_bin" "$repo_dir/bootstrap.sh" python >/dev/null
)
if ! grep -qF -- "install --quiet --upgrade pip ruff pytest" "$boot_dir/pip-calls"; then
  echo "fail: bootstrap.sh did not fall back to pip in the venv" >&2
  cat "$boot_dir/pip-calls" >&2
  exit 1
fi
echo "ok: bootstrap.sh falls back to pip without uv"

# clean-settings.sh must preserve valid JSON when the Snyk setting is not last.
clean_dir="$tmp_home/clean-settings"
mkdir -p "$clean_dir"
cp clean-settings.sh find-python.sh "$clean_dir/"
"$PYTHON" - "$clean_dir/settings.json" <<'PY'
import json
import sys

settings = {
    "first": True,
    "snyk.advanced.cliPath": "/" + "Users/example/Library/Application Support/snyk/cli",
    "nested": {"value": True},
    "last": True,
}
json.dump(settings, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY
bash "$clean_dir/clean-settings.sh" >/dev/null
"$PYTHON" - "$clean_dir/settings.json" <<'PY'
import json
import sys

settings = json.load(open(sys.argv[1], encoding="utf-8"))
assert "snyk.advanced.cliPath" not in settings
assert settings["nested"]["value"] is True
assert settings["last"] is True
PY

"$PYTHON" - "$clean_dir/settings.json" <<'PY'
import sys
from pathlib import Path

home = "/" + "Users/example/Library/Application Support/snyk/cli"
Path(sys.argv[1]).write_text(
    '{\n  "nested": {"value": true},\n'
    f'  "snyk.advanced.cliPath": "{home}"\n'
    '  // Optional settings remain below the last property.\n}\n',
    encoding="utf-8",
)
PY
bash "$clean_dir/clean-settings.sh" >/dev/null
"$PYTHON" - "$clean_dir/settings.json" <<'PY'
import json
import re
import sys

raw = open(sys.argv[1], encoding="utf-8").read()
settings = json.loads(re.sub(r"^[ \t]*//.*$", "", raw, flags=re.M))
assert "snyk.advanced.cliPath" not in settings
assert settings["nested"]["value"] is True
PY

"$PYTHON" - "$clean_dir/settings.json" <<'PY'
import sys
from pathlib import Path

home = "c:\\\\Users\\\\example\\\\Desktop\\\\project"
Path(sys.argv[1]).write_text(
    '{\n  "nested": {"value": true},\n'
    '  "snyk.trustedFolders": [\n'
    f'    "{home}",\n'
    f'    "{home}2"\n'
    '  ],\n'
    f'  "snyk.advanced.cliPath": "{home}",\n'
    '  "snyk.advanced.customEndpoint": "https://api.snyk.io",\n'
    '  "last": true\n}\n',
    encoding="utf-8",
)
PY
bash "$clean_dir/clean-settings.sh" >/dev/null
"$PYTHON" - "$clean_dir/settings.json" <<'PY'
import json
import sys

settings = json.load(open(sys.argv[1], encoding="utf-8"))
assert not any(k.startswith("snyk.") for k in settings), list(settings)
assert settings["last"] is True
PY

# Continue registers its config schema under yaml.schemas with an absolute
# path into its own extension directory, as the last property.
"$PYTHON" - "$clean_dir/settings.json" <<'PY'
import sys
from pathlib import Path

home = "/" + "Users/example/.vscode/extensions/continue.continue-2.0.0-darwin-arm64"
Path(sys.argv[1]).write_text(
    '{\n  "[markdown]": {\n    "files.trimTrailingWhitespace": false\n  },\n'
    '  "yaml.schemas": {\n'
    f'    "file://{home}/config-yaml-schema.json": [\n'
    '      ".continue/**/*.yaml"\n'
    '    ]\n'
    '  }\n'
    '  // Optional settings remain below the last property.\n}\n',
    encoding="utf-8",
)
PY
bash "$clean_dir/clean-settings.sh" >/dev/null
"$PYTHON" - "$clean_dir/settings.json" <<'PY'
import json
import re
import sys

raw = open(sys.argv[1], encoding="utf-8").read()
settings = json.loads(re.sub(r"^[ \t]*//.*$", "", raw, flags=re.M))
assert "yaml.schemas" not in settings
assert settings["[markdown]"]["files.trimTrailingWhitespace"] is False
PY

# The guard pattern must catch JSON-escaped Windows paths.
home_paths_probe='[A-Za-z]:[\\/]{1,2}(Users|Documents and Settings)[\\/]{1,2}[^\\/[:space:]"]+'
printf '"x": "c:\\\\Users\\\\example\\\\CV"\n' >"$clean_dir/pathprobe"
if ! grep -qE "$home_paths_probe" "$clean_dir/pathprobe"; then
  echo "fail: home path pattern misses JSON-escaped Windows paths" >&2
  exit 1
fi

echo "ok: clean-settings.sh preserves valid JSON"

# Rewriting must not flip the file to CRLF: .gitattributes and .editorconfig
# both mandate LF, and Python rewrites a file with CRLF on Windows by default.
"$PYTHON" - "$clean_dir/settings.json" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(
    '{\n  "keep": true,\n'
    '  "snyk.advanced.customEndpoint": "https://api.snyk.io"\n}\n',
    encoding="utf-8",
    newline="\n",
)
PY
bash "$clean_dir/clean-settings.sh" >/dev/null
"$PYTHON" - "$clean_dir/settings.json" <<'PY'
import json
import sys

data = open(sys.argv[1], "rb").read()
if b"\r\n" in data:
    raise SystemExit("fail: clean-settings.sh rewrote settings.json with CRLF")
assert json.loads(data)["keep"] is True
PY
echo "ok: clean-settings.sh keeps LF line endings"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x install.sh test.sh clean-settings.sh bootstrap.sh find-python.sh
  echo "ok: shellcheck"
else
  echo "skip: shellcheck not installed"
fi

# Keep this last: a running extension may rewrite settings during the test.
home_paths='/(Users|home)/[^/[:space:]"]+|[A-Za-z]:[\\/]{1,2}(Users|Documents and Settings)[\\/]{1,2}[^\\/[:space:]"]+'
check_no_paths() {
  label="$1"
  shift
  if hits="$("$@")"; then
    echo "$hits" >&2
    echo "fail: machine-specific home path found in $label (run ./clean-settings.sh)" >&2
    exit 1
  elif [ "$?" -ne 1 ]; then
    echo "fail: could not scan $label for machine-specific paths" >&2
    exit 1
  fi
}
check_no_paths "working tree" grep -rIlE "$home_paths" --exclude-dir=.git --exclude-dir=.venv --exclude-dir=__pycache__ .
if git rev-parse --git-dir >/dev/null 2>&1; then
  check_no_paths "git index" git grep --cached -IlE "$home_paths"
fi
echo "ok: no machine-specific paths"

echo "all checks passed"
