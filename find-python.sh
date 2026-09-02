#!/usr/bin/env bash
# Sets PYTHON to a working Python 3 command, or leaves it empty; sourced by
# bootstrap.sh, clean-settings.sh and test.sh.
# python3 does not exist on a stock Windows install, and the name is a Microsoft
# Store stub when Python was never installed — probe each candidate instead.
PYTHON=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(sys.version_info[0] != 3)' >/dev/null 2>&1; then
    PYTHON="$candidate"
    break
  fi
done
# The py launcher is Windows-only and needs a version flag; resolve it to the
# interpreter path so the command stays one word, quotable on bash 3.2 too.
if [ -z "$PYTHON" ] && command -v py >/dev/null 2>&1; then
  PYTHON="$(py -3 -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
fi
