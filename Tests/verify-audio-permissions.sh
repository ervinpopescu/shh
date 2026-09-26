#!/usr/bin/env bash
# Verify that the built app declares the privacy descriptions required by voice recording.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 path/to/Shh.app" >&2
  exit 2
fi

plist="$1/Info.plist"
if [[ ! -f "$plist" ]]; then
  echo "missing built app Info.plist: $plist" >&2
  exit 1
fi

python3 - "$plist" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
with plist_path.open("rb") as handle:
    plist = plistlib.load(handle)

required = {
    "NSMicrophoneUsageDescription",
    "NSSpeechRecognitionUsageDescription",
}
missing_or_empty = [
    key for key in sorted(required) if not isinstance(plist.get(key), str) or not plist[key].strip()
]
if missing_or_empty:
    raise SystemExit(
        "built app is missing non-empty privacy descriptions: "
        + ", ".join(missing_or_empty)
    )

print(f"Audio privacy descriptions are valid in {plist_path}")
PY
