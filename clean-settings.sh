#!/usr/bin/env bash
# Removes machine-specific keys that extensions write into settings.json:
# snyk.* and yaml.schemas.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# python3 does not exist on a stock Windows install, and the name is a Microsoft
# Store stub when Python was never installed — probe each candidate instead.
PYTHON=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c '' >/dev/null 2>&1; then
    PYTHON="$candidate"
    break
  fi
done
# The py launcher is Windows-only and needs a version flag; resolve it to the
# interpreter path so the command stays one word, quotable on bash 3.2 too.
if [ -z "$PYTHON" ] && command -v py >/dev/null 2>&1; then
  PYTHON="$(py -3 -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
fi
if [ -z "$PYTHON" ]; then
  echo "no Python 3 found (tried python3, python, py -3)" >&2
  exit 1
fi

"$PYTHON" - <<'PY'
import json
import re
from pathlib import Path

path = Path("settings.json")
lines = path.read_text(encoding="utf-8").splitlines(True)

# yaml.schemas goes as a whole: the baseline defines none of its own.
top_key = re.compile(r'^\s*"(snyk\.[^"]*|yaml\.schemas)"\s*:')

def brackets(line):
    # Path values never contain brackets, so counting inside strings is safe.
    return line.count("[") + line.count("{") - line.count("]") - line.count("}")

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

# The default would rewrite the whole file with CRLF on Windows.
path.write_text("".join(kept), encoding="utf-8", newline="\n")
print(f"removed {removed} machine-specific line(s)")
PY
