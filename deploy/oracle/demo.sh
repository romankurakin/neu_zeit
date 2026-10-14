#!/usr/bin/env bash
set -euo pipefail
directory="$(cd -- "$(dirname -- "$0")" && pwd)"
exec "${ORACLE_PYTHON:-python3}" "$directory/demo.py" "$@"
