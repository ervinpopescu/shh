#!/usr/bin/env bash
set -euo pipefail

project=${1:-Shh.xcodeproj}
destination=${2:-generic/platform=iOS}
expected_group="group.com.ervinpopescu.shh"

for entitlements in App/Shh.entitlements FileProviderExtension/ShhFileProvider.entitlements; do
  actual=$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.security.application-groups:0' "$entitlements"
  )
  if [[ "$actual" != "$expected_group" ]]; then
    echo "Unexpected App Group in $entitlements: $actual" >&2
    exit 1
  fi
done

settings_for() {
  xcodebuild -showBuildSettings \
    -project "$project" \
    -scheme "$1" \
    -configuration Debug \
    -destination "$destination"
}

app_settings=$(settings_for Shh)
extension_settings=$(settings_for ShhFileProvider)

grep -Eq '^    CODE_SIGN_ENTITLEMENTS = App/Shh.entitlements$' \
  <<< "$app_settings"
grep -Eq '^    CODE_SIGN_ENTITLEMENTS = FileProviderExtension/' \
  <<< "$extension_settings"
grep -Eq 'ShhFileProvider.entitlements$' <<< "$extension_settings"

test_settings=$(
  xcodebuild -showBuildSettings \
    -project "$project" \
    -target ShhAppTests \
    -configuration Debug
)
if grep -Eq '^    CODE_SIGN_ENTITLEMENTS = .+' <<< "$test_settings"; then
  echo "ShhAppTests must not carry an App Group entitlement" >&2
  exit 1
fi

echo "App Group entitlements validated for $project ($destination)"
