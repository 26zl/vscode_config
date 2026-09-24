#!/usr/bin/env bash
# Removes machine-specific keys that extensions write into settings.json:
# snyk.*, yaml.schemas and yaml.disableSchemaDetection. With --filter it reads
# stdin and writes stdout instead, as the Git clean filter install.sh sets up.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# shellcheck source=find-python.sh
. ./find-python.sh
if [ -z "$PYTHON" ]; then
  echo "no Python 3 found (tried python3, python, py -3)" >&2
  exit 1
fi

# Strips the keys from the file named in $1, in place.
clean() {
  "$PYTHON" - "$1" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(True)

# yaml.schemas and yaml.disableSchemaDetection go as a whole: the baseline sets neither.
top_key = re.compile(r'^\s*"(snyk\.[^"]*|yaml\.schemas|yaml\.disableSchemaDetection)"\s*:')

def brackets(line):
    structural = re.sub(r'"(?:\\.|[^"\\])*"', "", line).split("//", 1)[0]
    return structural.count("[") + structural.count("{") - structural.count("]") - structural.count("}")

kept, removed, depth, skipping = [], 0, 0, False
for line in lines:
    if skipping:
        removed += 1
        depth += brackets(line)
        if depth <= 0:
            skipping = False
        continue
    if top_key.match(line):
        removed += 1
        depth = brackets(line)
        skipping = depth > 0
        continue
    kept.append(line)

if not removed:
    print("settings.json already clean")
    raise SystemExit

def parse(candidate):
    raw = "".join(candidate)
    stripped = re.sub(r"^[ \t]*//.*$", "", raw, flags=re.M)
    json.loads(stripped)

try:
    parse(kept)
except json.JSONDecodeError:
    for index in range(len(kept) - 1, -1, -1):
        content = kept[index].strip()
        if not content or content.startswith("//") or content == "}":
            continue
        if content.endswith(","):
            kept[index] = kept[index].rstrip()[:-1] + ("\n" if kept[index].endswith("\n") else "")
        break
    parse(kept)

# Bytes avoid newline translation on Windows and work on older Python 3 releases.
path.write_bytes("".join(kept).encode("utf-8"))
print(f"removed {removed} machine-specific line(s)")
PY
}

if [ "${1:-}" = "--filter" ]; then
  # The Python program itself arrives on stdin, so the content goes through a file.
  staged="$(mktemp)"
  trap 'rm -f "$staged"' EXIT
  cat >"$staged"
  clean "$staged" >/dev/null
  cat "$staged"
else
  clean settings.json
fi
