#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

bash -n linux/dune-native.sh
python -m pytest -q tests/test_dune_native.py "$@"
