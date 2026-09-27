#!/usr/bin/env bash
# Downloads VSIX packages, their dependencies and Marketplace signatures into
# DIR for an offline install; install.sh --download calls it.
# Usage: ./download-vsix.sh DIR PLATFORM CODE_VERSION ID[@VERSION]...
set -euo pipefail

# shellcheck source=find-python.sh
. "$(dirname "${BASH_SOURCE[0]}")/find-python.sh"
if [ -z "$PYTHON" ]; then
  echo "no Python 3 found (tried python3, python, py -3)" >&2
  exit 1
fi

"$PYTHON" - "$@" <<'PY'
import calendar
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

out, platform, code_version, *wanted = sys.argv[1:]
gallery = os.environ.get("VSIX_GALLERY", "https://marketplace.visualstudio.com/_apis/public/gallery")
# Same rule as extensions.autoUpdateDelay: no release younger than 5 days.
min_age = 5 * 24 * 3600


def ver(text):
    core = text.lstrip("^~>=v").split("-")[0]
    return tuple(int(part) if part.isdigit() else 0 for part in core.split("."))


def prop(version, key):
    return next((p["value"] for p in version.get("properties", []) if p["key"] == key), "")


def query(ext_id):
    criteria = [
        {"filterType": 8, "value": "Microsoft.VisualStudio.Code"},
        {"filterType": 12, "value": "4096"},
        {"filterType": 7, "value": ext_id},
    ]
    # Flags: every version, its properties and its asset URI.
    body = json.dumps({"filters": [{"criteria": criteria}], "flags": 0x1 | 0x10 | 0x80}).encode()
    request = urllib.request.Request(
        gallery + "/extensionquery",
        data=body,
        headers={"Content-Type": "application/json", "Accept": "application/json;api-version=3.0-preview.1"},
    )
    with urllib.request.urlopen(request, timeout=300) as response:
        found = json.load(response)["results"][0]["extensions"]
    return next((e for e in found if f'{e["publisher"]["publisherName"]}.{e["extensionName"]}'.lower() == ext_id), None)


def fits(version, pin):
    if version.get("targetPlatform", "universal") not in ("universal", platform):
        return False
    if ver(prop(version, "Microsoft.VisualStudio.Code.Engine")) > ver(code_version):
        return False
    if pin:
        return version["version"] == pin
    released = calendar.timegm(time.strptime(version["lastUpdated"][:19], "%Y-%m-%dT%H:%M:%S"))
    return prop(version, "Microsoft.VisualStudio.Code.PreRelease") != "true" and time.time() - released >= min_age


def fetch(url, path):
    with urllib.request.urlopen(url, timeout=300) as response:
        path.write_bytes(response.read())


target = Path(out)
target.mkdir(parents=True, exist_ok=True)
for old in [*target.glob("*.vsix"), *target.glob("*.sigzip")]:
    old.unlink()

# Entries: (id, pinned version, optional); pack members are optional, as in VS Code.
queue = [(w.split("@")[0].lower(), w.partition("@")[2], False) for w in wanted]
seen, failed = set(), []
while queue:
    ext_id, pin, optional = queue.pop(0)
    # Built-in extensions (publisher "vscode") ship with VS Code, not the gallery.
    if ext_id in seen or ext_id.startswith("vscode."):
        continue
    seen.add(ext_id)
    try:
        ext = query(ext_id)
        # Newest fitting version; a platform build beats the universal one.
        version = max(
            (v for v in ext["versions"] if fits(v, pin)) if ext else [],
            key=lambda v: (ver(v["version"]), v.get("targetPlatform", "universal") != "universal"),
            default=None,
        )
        if not version:
            wanted_release = f"no version {pin}" if pin else "no stable release at least 5 days old"
            reason = f"{wanted_release} for {platform} and VS Code {code_version}" if ext else "not in the gallery"
            if optional:
                print(f"skipped pack member {ext_id}: {reason}")
                continue
            raise ValueError(reason)
        name = f'{ext_id}-{version["version"]}'
        vsix = target / f"{name}.vsix"
        fetch(version["assetUri"] + "/Microsoft.VisualStudio.Services.VSIXPackage", vsix)
        sha = prop(version, "Microsoft.VisualStudio.Services.VsixSha256").lower()
        if sha and hashlib.sha256(vsix.read_bytes()).hexdigest() != sha:
            vsix.unlink()
            raise ValueError("checksum does not match the Marketplace")
        try:
            fetch(version["assetUri"] + "/Microsoft.VisualStudio.Services.VsixSignature", target / f"{name}.sigzip")
        except urllib.error.HTTPError as error:
            vsix.unlink()
            if error.code != 404:
                raise
            raise ValueError("no Marketplace signature, so it cannot be verified offline") from None
    except (OSError, ValueError) as error:
        failed.append(f"{ext_id}: {error}")
        continue
    except (KeyError, TypeError) as error:
        failed.append(f"{ext_id}: unexpected gallery response ({error!r})")
        continue
    print(f'{ext_id} {version["version"]} ({version.get("targetPlatform", "universal")})')
    for key, pack in (("ExtensionDependencies", False), ("ExtensionPack", True)):
        for dep in filter(None, prop(version, f"Microsoft.VisualStudio.Code.{key}").split(",")):
            queue.append((dep.strip().lower(), "", pack))

if failed:
    sys.exit("failed:\n  " + "\n  ".join(failed))
print(f"{len(list(target.glob('*.vsix')))} extension(s) in {target}")
PY
