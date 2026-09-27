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
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  echo "1.124.9"
  exit 0
fi
exit 0
SH
chmod +x "$fake_bin/code"
old_code_home="$tmp_home/old-code-home"
if PATH="$fake_bin:$PATH" run_install "$old_code_home" >/dev/null 2>&1; then
  echo "fail: install.sh accepted VS Code older than 1.125" >&2
  exit 1
fi
if [ -e "$old_code_home" ]; then
  echo "fail: install.sh changed HOME before the VS Code version check failed" >&2
  exit 1
fi
echo "ok: install.sh requires VS Code 1.125"

# The Remote-WSL/SSH wrapper prints server download progress before the version.
cat >"$fake_bin/code" <<'SH'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  echo "Installing VS Code Server for Linux x64 (abc123)"
  echo "1.139.1"
  echo "abc123"
  echo "x64"
  exit 0
fi
exit 0
SH
chmod +x "$fake_bin/code"
wrapper_home="$tmp_home/wrapper-home"
if ! PATH="$fake_bin:$PATH" run_install "$wrapper_home" --groups ops >/dev/null 2>&1; then
  echo "fail: install.sh rejected the version behind the remote wrapper's install output" >&2
  exit 1
fi
echo "ok: install.sh reads the version past the remote wrapper's output"

cat >"$fake_bin/code" <<'SH'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  echo "1.125.0"
  exit 0
fi
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
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  echo "1.125.0"
else
  echo "$@"
fi
SH
# On Windows a role also takes the Windows-only group.
role_groups=core,k8s,ops
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) role_groups=core,k8s,ops,windows ;;
esac
role_out="$(PATH="$fake_bin:$PATH" run_install "$tmp_home" --role sysadmin 2>/dev/null | grep -- --install-extension | sort)"
groups_out="$(PATH="$fake_bin:$PATH" run_install "$tmp_home" --groups "$role_groups" 2>/dev/null | grep -- --install-extension | sort)"
if [ -z "$role_out" ] || [ "$role_out" != "$groups_out" ]; then
  echo "fail: --role sysadmin does not match --groups $role_groups" >&2
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

typo_home="$tmp_home/typo-home"
if PATH="$fake_bin:$PATH" run_install "$typo_home" --groups nosuchgroup >/dev/null 2>&1; then
  echo "fail: install.sh accepted an unknown group" >&2
  exit 1
fi
if [ -e "$typo_home" ]; then
  echo "fail: install.sh changed HOME before rejecting an unknown group" >&2
  exit 1
fi
echo "ok: install.sh rejects unknown groups before changing settings"

cat >"$fake_bin/code" <<'SH'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  echo "1.125.0"
  exit 0
fi
if [ "${1:-}" = "--profile" ] && [ "${3:-}" = "--list-extensions" ]; then
  exit 1
fi
exit 0
SH
chmod +x "$fake_bin/code"
profile_home="$tmp_home/profile-home"
if PATH="$fake_bin:$PATH" run_install "$profile_home" --profile Missing >/dev/null 2>&1; then
  echo "fail: install.sh accepted an unavailable profile" >&2
  exit 1
fi
if [ -e "$profile_home" ]; then
  echo "fail: install.sh changed HOME before the profile preflight failed" >&2
  exit 1
fi
echo "ok: install.sh checks profiles before changing settings"

# --download fills a bundle from a local gallery fixture; --offline verifies
# that bundle and installs it without the Marketplace.
case "$(uname -s)" in
Darwin) offline_platform="darwin-x64" ;;
MINGW* | MSYS* | CYGWIN*) offline_platform="win32-x64" ;;
*) offline_platform="linux-x64" ;;
esac
offline_repo="$tmp_home/offline-repo"
fake_app="$tmp_home/fake-app"
sign_dir="$fake_app/node_modules.asar.unpacked/@vscode/vsce-sign/bin"
mkdir -p "$offline_repo" "$sign_dir"
cp install.sh download-vsix.sh find-python.sh settings.json "$offline_repo/"
printf '[core]\ntest.tool\ntest.pinned@0.1.0\n' >"$offline_repo/extensions.txt"
cat >"$sign_dir/vsce-sign" <<'SH'
#!/bin/sh
# Accepts a package only when its signature archive says "signed".
grep -q signed "$5"
SH
chmod +x "$sign_dir/vsce-sign"
cat >"$fake_bin/code" <<'SH'
#!/bin/sh
case "$1" in
--version) printf '1.139.0\nabc123\nx64\n' ;;
--locate-shell-integration-path) echo "$FAKE_APP/out/vs/workbench/contrib/terminal/common/scripts/shellIntegration-bash.sh" ;;
*) echo "$@" >>"$CODE_CALLS" ;;
esac
SH
"$PYTHON" - "$tmp_home/gallery" "$offline_platform" <<'PY'
import hashlib
import json
import sys
import time
from pathlib import Path

root, platform = Path(sys.argv[1]), sys.argv[2]


def version(ext_id, number, target=None, engine="^1.100.0", days_old=30, prerelease=False, deps=""):
    assets = root / ext_id / number / (target or "universal")
    assets.mkdir(parents=True)
    package = f"{ext_id} {number} {target}".encode()
    (assets / "Microsoft.VisualStudio.Services.VSIXPackage").write_bytes(package)
    (assets / "Microsoft.VisualStudio.Services.VsixSignature").write_text("signed")
    props = {
        "Microsoft.VisualStudio.Code.Engine": engine,
        "Microsoft.VisualStudio.Code.PreRelease": str(prerelease).lower(),
        "Microsoft.VisualStudio.Code.ExtensionDependencies": deps,
        "Microsoft.VisualStudio.Services.VsixSha256": hashlib.sha256(package).hexdigest(),
    }
    entry = {
        "version": number,
        "lastUpdated": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - days_old * 86400)),
        "assetUri": assets.resolve().as_uri(),
        "properties": [{"key": k, "value": v} for k, v in props.items()],
    }
    if target:
        entry["targetPlatform"] = target
    return entry


def extension(ext_id, *versions):
    publisher, name = ext_id.split(".")
    return {"publisher": {"publisherName": publisher}, "extensionName": name, "versions": list(versions)}


# Only the platform build of 1.9.0 fits: newer ones are too new for VS Code,
# pre-release, younger than 5 days or for another platform.
extensions = [
    extension(
        "test.tool",
        version("test.tool", "3.0.0", platform, engine="^1.200.0"),
        version("test.tool", "2.2.0", platform, prerelease=True),
        version("test.tool", "2.1.0", platform, days_old=1),
        version("test.tool", "2.0.0", "other-os"),
        version("test.tool", "1.9.0"),
        version("test.tool", "1.9.0", platform, deps="test.dep,vscode.builtin"),
    ),
    extension("test.dep", version("test.dep", "1.0.0")),
    extension("test.pinned", version("test.pinned", "0.2.0"), version("test.pinned", "0.1.0")),
]
(root / "extensionquery").write_text(json.dumps({"results": [{"extensions": extensions}]}))
PY
gallery="$("$PYTHON" -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$tmp_home/gallery")"
# Runs the copied install.sh with the fake code CLI against a sandbox home.
run_offline_repo() {
  home="$1"
  shift
  PATH="$fake_bin:$PATH" FAKE_APP="$fake_app" CODE_CALLS="$tmp_home/code-calls" VSIX_GALLERY="$gallery" \
    HOME="$home" APPDATA="$home/AppData/Roaming" XDG_CONFIG_HOME='' bash "$offline_repo/install.sh" "$@"
}
run_offline_repo "$tmp_home/download-home" --download >/dev/null
bundle="$offline_repo/vsix/$offline_platform"
got="$(cd "$bundle" && LC_ALL=C && printf '%s ' *)"
if [ "$got" != "test.dep-1.0.0.sigzip test.dep-1.0.0.vsix test.pinned-0.1.0.sigzip test.pinned-0.1.0.vsix test.tool-1.9.0.sigzip test.tool-1.9.0.vsix " ]; then
  echo "fail: --download picked the wrong packages: $got" >&2
  exit 1
fi
if ! grep -q "$offline_platform" "$bundle/test.tool-1.9.0.vsix"; then
  echo "fail: --download took the universal build over the platform one" >&2
  exit 1
fi
if [ -e "$tmp_home/download-home" ]; then
  echo "fail: --download changed HOME" >&2
  exit 1
fi
echo "ok: install.sh --download picks fitting releases and their dependencies"

: >"$tmp_home/code-calls"
run_offline_repo "$tmp_home/offline-home" --offline >/dev/null
if [ "$(grep -c -- '--do-not-include-pack-dependencies' "$tmp_home/code-calls")" -ne 3 ] ||
  [ ! -L "$(user_dir_for "$tmp_home/offline-home")/settings.json" ]; then
  echo "fail: --offline did not link settings and install the bundle" >&2
  cat "$tmp_home/code-calls" >&2
  exit 1
fi
echo tampered >"$bundle/test.dep-1.0.0.sigzip"
if run_offline_repo "$tmp_home/tampered-home" --offline >/dev/null 2>&1; then
  echo "fail: --offline installed a package with a bad signature" >&2
  exit 1
fi
if [ -e "$tmp_home/tampered-home" ]; then
  echo "fail: --offline changed HOME before the signature check" >&2
  exit 1
fi
echo "ok: install.sh --offline verifies the bundle before it changes anything"

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
if ! grep -qF -- "pip install --upgrade --python $want_python ruff pytest" "$boot_dir/uv-calls"; then
  echo "fail: bootstrap.sh did not upgrade the toolset in $want_python" >&2
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

py_bin="$tmp_home/py-bin"
mkdir -p "$py_bin"
cat >"$py_bin/python3" <<'SH'
#!/bin/sh
[ -z "${2:-}" ]
SH
cp "$py_bin/python3" "$py_bin/python"
cat >"$py_bin/py" <<'SH'
#!/bin/sh
printf '%s\n' "$PY_FALLBACK_TARGET"
SH
chmod +x "$py_bin/python3" "$py_bin/python" "$py_bin/py"
# shellcheck disable=SC2016  # Variables expand in the child shell.
if ! PATH="$py_bin" PY_FALLBACK_TARGET="$(command -v "$PYTHON")" "$bash_bin" -c '. ./find-python.sh; [ "$PYTHON" = "$PY_FALLBACK_TARGET" ]'; then
  echo "fail: find-python.sh accepted a non-Python-3 interpreter" >&2
  exit 1
fi
echo "ok: find-python.sh requires Python 3 and falls back to py -3"

# clean-settings.sh must preserve valid JSON when the Snyk setting is not last.
clean_dir="$tmp_home/clean-settings"
mkdir -p "$clean_dir"
cp clean-settings.sh find-python.sh "$clean_dir/"
"$PYTHON" - "$clean_dir/settings.json" <<'PY'
import json
import sys

settings = {
    "first": True,
    "snyk.advanced.cliPath": "/" + "Users/example/[workspace/snyk/cli",
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

# vscode-yaml writes yaml.disableSchemaDetection for the extensions it defers
# to; Continue registers its config schema under yaml.schemas with an absolute
# path into its own extension directory, as the last property.
"$PYTHON" - "$clean_dir/settings.json" <<'PY'
import sys
from pathlib import Path

home = "/" + "Users/example/.vscode/extensions/continue.continue-2.0.0-darwin-arm64"
Path(sys.argv[1]).write_text(
    '{\n  "[markdown]": {\n    "files.trimTrailingWhitespace": false\n  },\n'
    '  "yaml.disableSchemaDetection": [\n'
    '    "**/compose.yml"\n'
    '  ],\n'
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
assert "yaml.disableSchemaDetection" not in settings
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

# The Git clean filter install.sh configures drops extension-written keys on
# git add and passes a clean file through byte for byte.
filter_repo="$tmp_home/filter-repo"
mkdir -p "$filter_repo"
cp install.sh clean-settings.sh find-python.sh .gitattributes "$filter_repo/"
git -C "$filter_repo" init -q
printf '{\n  "keep": true,\n  "yaml.disableSchemaDetection": ["**/compose.yml"]\n}\n' >"$filter_repo/settings.json"
HOME="$tmp_home/filter-home" APPDATA="$tmp_home/filter-home/AppData/Roaming" XDG_CONFIG_HOME='' \
  bash "$filter_repo/install.sh" --no-ext >/dev/null
git -C "$filter_repo" add settings.json
if [ "$(git -C "$filter_repo" show :settings.json)" != "$(printf '{\n  "keep": true\n}')" ]; then
  echo "fail: git add kept extension-written keys despite the clean filter" >&2
  exit 1
fi
printf '{\n  "keep": false\n}\n' >"$filter_repo/settings.json"
git -C "$filter_repo" add settings.json
if ! git -C "$filter_repo" show :settings.json | cmp -s - "$filter_repo/settings.json"; then
  echo "fail: the clean filter changed a file without extension-written keys" >&2
  exit 1
fi
echo "ok: git add drops extension-written keys through the clean filter"

# Whatever clean-settings.sh strips must never reach a commit.
if git rev-parse --git-dir >/dev/null 2>&1; then
  git show :settings.json >"$clean_dir/settings.json"
  if [ "$(bash "$clean_dir/clean-settings.sh")" != "settings.json already clean" ]; then
    echo "fail: extension-written keys staged in settings.json (run ./clean-settings.sh)" >&2
    exit 1
  fi
  echo "ok: no extension-written keys staged"
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x install.sh test.sh clean-settings.sh bootstrap.sh find-python.sh download-vsix.sh
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
