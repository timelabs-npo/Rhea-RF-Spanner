#!/bin/bash
# Entry point only. Credential material is handled by Python without shell expansion.
set +x
set -euo pipefail
exec python3 "$(dirname "$0")/testflight.py" "$@"
