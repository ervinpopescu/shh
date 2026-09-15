#!/bin/bash
# Verify the source catalog and, when supplied, the compiled application's icon metadata.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
appicon_dir="$repo_root/Resources/Assets.xcassets/AppIcon.appiconset"
project_spec="$repo_root/project.yml"

if ! grep -q 'ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon' "$project_spec"; then
  echo "project.yml does not select AppIcon" >&2
  exit 1
fi

python3 - "$appicon_dir" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

catalog = Path(sys.argv[1])
contents_path = catalog / "Contents.json"
contents = json.loads(contents_path.read_text())
images = contents.get("images")
if not isinstance(images, list):
    raise SystemExit("Contents.json has no images array")

expected = {
    ("iphone", "20x20", "2x"): ("AppIcon-20@2x.png", 40),
    ("iphone", "20x20", "3x"): ("AppIcon-20@3x.png", 60),
    ("iphone", "29x29", "2x"): ("AppIcon-29@2x.png", 58),
    ("iphone", "29x29", "3x"): ("AppIcon-29@3x.png", 87),
    ("iphone", "40x40", "2x"): ("AppIcon-40@2x.png", 80),
    ("iphone", "40x40", "3x"): ("AppIcon-40@3x.png", 120),
    ("iphone", "60x60", "2x"): ("AppIcon-60@2x.png", 120),
    ("iphone", "60x60", "3x"): ("AppIcon-60@3x.png", 180),
    ("ipad", "20x20", "1x"): ("AppIcon-iPad-20.png", 20),
    ("ipad", "20x20", "2x"): ("AppIcon-iPad-20@2x.png", 40),
    ("ipad", "29x29", "1x"): ("AppIcon-iPad-29.png", 29),
    ("ipad", "29x29", "2x"): ("AppIcon-iPad-29@2x.png", 58),
    ("ipad", "40x40", "1x"): ("AppIcon-iPad-40.png", 40),
    ("ipad", "40x40", "2x"): ("AppIcon-iPad-40@2x.png", 80),
    ("ipad", "76x76", "1x"): ("AppIcon-iPad-76.png", 76),
    ("ipad", "76x76", "2x"): ("AppIcon-iPad-76@2x.png", 152),
    ("ipad", "83.5x83.5", "2x"): ("AppIcon-iPad-83.5@2x.png", 167),
    ("ios-marketing", "1024x1024", "1x"): ("AppIcon-1024.png", 1024),
}
actual = {(i.get("idiom"), i.get("size"), i.get("scale")): i for i in images}
if set(actual) != set(expected):
    raise SystemExit(f"icon slots differ: expected {set(expected)}, found {set(actual)}")

for slot, (filename, pixels) in expected.items():
    entry = actual[slot]
    if entry.get("filename") != filename:
        raise SystemExit(f"{slot} points to {entry.get('filename')!r}, expected {filename!r}")
    path = catalog / filename
    if not path.is_file():
        raise SystemExit(f"missing icon file: {path}")
    output = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)], text=True)
    dimensions = [int(line.split(":", 1)[1].strip()) for line in output.splitlines() if ":" in line]
    if dimensions != [pixels, pixels]:
        raise SystemExit(f"{filename} is {dimensions}, expected {[pixels, pixels]}")
PY

if [[ $# -eq 0 ]]; then
  echo "AppIcon source catalog is valid"
  exit 0
fi

app_bundle=$1
plist="$app_bundle/Info.plist"
if [[ ! -f "$plist" ]]; then
  echo "missing built app Info.plist: $plist" >&2
  exit 1
fi

icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$plist" 2>/dev/null || true)
ipad_icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconName' "$plist" 2>/dev/null || true)
if [[ "$icon_name" != "AppIcon" || "$ipad_icon_name" != "AppIcon" ]]; then
  echo "built app icons are iphone=${icon_name:-unset}, ipad=${ipad_icon_name:-unset}; expected AppIcon" >&2
  exit 1
fi

for generated_icon in AppIcon60x60@2x.png AppIcon76x76@2x~ipad.png; do
  if [[ ! -f "$app_bundle/$generated_icon" ]]; then
    echo "missing compiled icon: $app_bundle/$generated_icon" >&2
    exit 1
  fi
done

echo "AppIcon source catalog and built bundle are valid"
