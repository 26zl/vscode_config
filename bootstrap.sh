#!/usr/bin/env bash
# Creates .venv in the CURRENT directory and installs a Python toolset into it,
# then reports which system tools the extensions expect but cannot install.
# Usage: ./bootstrap.sh [ansible|python|all]
set -euo pipefail

case "${1:-ansible}" in
ansible) packages="ansible ansible-lint yamllint ruff ansible-navigator ansible-creator" ;;
python) packages="ruff pytest" ;;
all) packages="ansible ansible-lint yamllint ruff ansible-navigator ansible-creator pytest" ;;
*)
  echo "usage: $0 [ansible|python|all]" >&2
  exit 2
  ;;
esac

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

if command -v uv >/dev/null 2>&1; then
  # uv venv refuses an existing .venv; reuse it so reruns just update packages.
  [ -d .venv ] || uv venv .venv
elif [ -n "$PYTHON" ]; then
  [ -d .venv ] || "$PYTHON" -m venv .venv
else
  echo "no Python 3 found (tried uv, python3, python, py -3)" >&2
  exit 1
fi

# Windows venvs put executables in Scripts/ with an .exe suffix, POSIX ones in
# bin/ without one. Resolve the layout once, after the venv exists.
if [ -x .venv/Scripts/python.exe ]; then
  venv_bin=".venv/Scripts"
  venv_ext=".exe"
else
  venv_bin=".venv/bin"
  venv_ext=""
fi
venv_python="$venv_bin/python$venv_ext"

if [ ! -x "$venv_python" ]; then
  echo "no interpreter at $venv_python; remove .venv and rerun" >&2
  exit 1
fi

if command -v uv >/dev/null 2>&1; then
  # shellcheck disable=SC2086  # deliberate word splitting into separate packages
  uv pip install --python "$venv_python" $packages
else
  # shellcheck disable=SC2086
  "$venv_python" -m pip install --quiet --upgrade pip $packages
fi
echo "ready: .venv with $packages"

# Project Python dependencies, when declared.
if [ -f requirements.txt ]; then
  if command -v uv >/dev/null 2>&1; then
    uv pip install --python "$venv_python" -r requirements.txt
  else
    "$venv_python" -m pip install --quiet -r requirements.txt
  fi
fi

# Pull the project's collections and roles when a requirements file exists.
if [ -f requirements.yml ] && [ -x "$venv_bin/ansible-galaxy$venv_ext" ]; then
  "$venv_bin/ansible-galaxy$venv_ext" install -r requirements.yml
fi

# Installing these needs a package manager and root; only report what is absent.
for tool in shellcheck shfmt terraform kubectl oc pwsh ansible-navigator; do
  command -v "$tool" >/dev/null 2>&1 || [ -x "$venv_bin/$tool$venv_ext" ] || echo "missing on PATH: $tool"
done
