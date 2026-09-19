#!/bin/bash
# Verify the generated application's local-network Bonjour declarations.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
plist="$repo_root/App/Info.plist"
if [[ $# -gt 0 ]]; then
  plist="$1/Info.plist"
fi

if [[ ! -f "$plist" ]]; then
  echo "missing generated app Info.plist: $plist" >&2
  exit 1
fi

python3 - "$plist" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
with plist_path.open("rb") as handle:
    plist = plistlib.load(handle)

expected_description = "Shh discovers SSH servers on your local network."
if plist.get("NSLocalNetworkUsageDescription") != expected_description:
    raise SystemExit("NSLocalNetworkUsageDescription is missing or incorrect")
if plist.get("NSBonjourServices") != ["_ssh._tcp"]:
    raise SystemExit("NSBonjourServices must be the array [_ssh._tcp]")

print(f"Bonjour local-network permissions are valid in {plist_path}")
PY
