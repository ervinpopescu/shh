# Shh development workflow. Use `just --list` for the composable lifecycle.
# Presets target the dedicated simulators; pass udid=... for another simulator or device.

set shell := ["bash", "-euo", "pipefail", "-c"]

xcode_developer_dir := env_var_or_default("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
iphone_udid := env_var_or_default("IPHONE_UDID", "F8EB87EE-3A18-4E0A-8FDF-0469E05E4001")
ipad_udid := env_var_or_default("IPAD_UDID", "BE4FD42F-96B9-4AD3-97EA-95FAB8059846")
derived_data := env_var_or_default("DERIVED_DATA_PATH", "build/DerivedData")
signing_identity := env_var_or_default("SIGNING_IDENTITY", "-")
signing_required := env_var_or_default("SIGNING_REQUIRED", "NO")
development_team := env_var_or_default("DEVELOPMENT_TEAM", "B7D575CY5M")

project := "Shh.xcodeproj"
app_scheme := "Shh"
test_scheme := "ShhAppTests"
bundle_id := "com.ervinpopescu.shh"

# Show all recipes and their arguments.
default:
    @just --list

# Check full Xcode, XcodeGen, Swift, Python, and simulator tooling.
doctor device="iphone" udid="":
    #!/usr/bin/env bash
    device="{{ device }}"; device="${device#device=}"
    udid="{{ udid }}"; udid="${udid#udid=}"
    developer_dir="{{ xcode_developer_dir }}"
    [[ -d "$developer_dir" ]] || { echo "Error: Xcode is unavailable at $developer_dir" >&2; exit 1; }
    export DEVELOPER_DIR="$developer_dir"
    for tool in xcodebuild xcrun xcodegen swift python3; do
        command -v "$tool" >/dev/null 2>&1 || { echo "Error: missing required tool: $tool" >&2; exit 1; }
    done
    xcodebuild -version
    if [[ -z "$udid" ]]; then
        case "$device" in
            iphone) target="{{ iphone_udid }}" ;;
            ipad) target="{{ ipad_udid }}" ;;
            *) echo "Error: device must be iphone or ipad when udid is empty" >&2; exit 2 ;;
        esac
    else
        target="$udid"
    fi
    if ! xcrun simctl list devices available -j | TARGET_UDID="$target" python3 -c 'import json, os, sys; target=os.environ["TARGET_UDID"]; data=json.load(sys.stdin); sys.exit(0 if any(device.get("udid")==target and device.get("isAvailable", True) for devices in data.get("devices", {}).values() for device in devices) else 1)'; then
        echo "Note: $target is not an available simulator; deploy/build will treat it as a physical device" >&2
    else
        echo "Simulator available: $target"
    fi

# Generate the ignored Xcode project from project.yml.
generate:
    #!/usr/bin/env bash
    export DEVELOPER_DIR="{{ xcode_developer_dir }}"
    command -v xcodegen >/dev/null 2>&1 || { echo "Error: install XcodeGen first" >&2; exit 1; }
    xcodegen generate --spec project.yml

# Format Swift sources in the same paths used by lint and format-check.
format:
    #!/usr/bin/env bash
    command -v swift-format >/dev/null 2>&1 || { echo "Error: swift-format is required (install it with brew install swift-format)" >&2; exit 1; }
    swift-format format --in-place --recursive App FileProviderExtension Sources Tests

# Check Swift formatting without changing files.
format-check:
    #!/usr/bin/env bash
    command -v swift-format >/dev/null 2>&1 || { echo "Error: swift-format is required (install it with brew install swift-format)" >&2; exit 1; }
    swift-format lint --recursive App FileProviderExtension Sources Tests

# Run Swift formatting and shell-script diagnostics.
lint:
    #!/usr/bin/env bash
    command -v swift-format >/dev/null 2>&1 || { echo "Error: swift-format is required (install it with brew install swift-format)" >&2; exit 1; }
    command -v shellcheck >/dev/null 2>&1 || { echo "Error: shellcheck is required (install it with brew install shellcheck)" >&2; exit 1; }
    swift-format lint --recursive App FileProviderExtension Sources Tests
    shellcheck Tests/*.sh

# Run the host-side Swift package unit and integration tests.
unit:
    #!/usr/bin/env bash
    export DEVELOPER_DIR="{{ xcode_developer_dir }}"
    swift test --enable-code-coverage

# Run formatting, lint, and host tests - the fast local quality gate.
check:
    #!/usr/bin/env bash
    just format-check
    just lint
    just unit

# Boot one selected simulator without erasing or resetting its data.
boot device="iphone" udid="":
    #!/usr/bin/env bash
    export DEVELOPER_DIR="{{ xcode_developer_dir }}"
    device="{{ device }}"; device="${device#device=}"
    udid="{{ udid }}"; udid="${udid#udid=}"
    [[ -z "$udid" ]] || { echo "Error: boot accepts simulator presets only; use deploy-device for a physical device" >&2; exit 2; }
    case "$device" in
        iphone) target="{{ iphone_udid }}" ;;
        ipad) target="{{ ipad_udid }}" ;;
        *) echo "Error: device must be iphone or ipad" >&2; exit 2 ;;
    esac
    if ! xcrun simctl list devices available -j | TARGET_UDID="$target" python3 -c 'import json, os, sys; target=os.environ["TARGET_UDID"]; data=json.load(sys.stdin); sys.exit(0 if any(device.get("udid")==target and device.get("isAvailable", True) for devices in data.get("devices", {}).values() for device in devices) else 1)'; then
        echo "Error: dedicated {{ device }} simulator is unavailable: $target" >&2
        exit 1
    fi
    state=$(xcrun simctl list devices -j | TARGET_UDID="$target" python3 -c 'import json, os, sys; target=os.environ["TARGET_UDID"]; data=json.load(sys.stdin); print(next((device.get("state", "") for devices in data.get("devices", {}).values() for device in devices if device.get("udid")==target), ""))')
    [[ "$state" == "Booted" ]] || xcrun simctl boot "$target"
    xcrun simctl bootstatus "$target" -b
    echo "Ready: $target"

# Build Shh for a preset simulator or an explicitly selected device.
build device="iphone" udid="":
    #!/usr/bin/env bash
    export DEVELOPER_DIR="{{ xcode_developer_dir }}"
    device="{{ device }}"; device="${device#device=}"
    udid="{{ udid }}"; udid="${udid#udid=}"
    if [[ -z "$udid" ]]; then
        case "$device" in
            iphone) target="{{ iphone_udid }}" ;;
            ipad) target="{{ ipad_udid }}" ;;
            *) echo "Error: device must be iphone or ipad when udid is empty" >&2; exit 2 ;;
        esac
    else
        target="$udid"
    fi
    simulator_state=$(xcrun simctl list devices -j | TARGET_UDID="$target" python3 -c 'import json, os, sys; target=os.environ["TARGET_UDID"]; data=json.load(sys.stdin); matches=[device for devices in data.get("devices", {}).values() for device in devices if device.get("udid")==target]; sys.exit(1) if not matches else print(("available:" if matches[0].get("isAvailable", True) else "unavailable:") + matches[0].get("state", "Shutdown"))' || true)
    case "$simulator_state" in
        available:*)
            destination="platform=iOS Simulator,id=$target"
            signing=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED="{{ signing_required }}" CODE_SIGN_IDENTITY="{{ signing_identity }}")
            ;;
        unavailable:*)
            echo "Error: simulator $target is unavailable; choose an available simulator or use a physical-device UDID" >&2
            exit 1
            ;;
        *)
            destination="platform=iOS,id=$target"
            signing=(DEVELOPMENT_TEAM="{{ development_team }}" CODE_SIGN_STYLE=Automatic)
            ;;
    esac
    mkdir -p "{{ derived_data }}"
    xcodegen generate --spec project.yml >/dev/null
    xcodebuild build \
        -project "{{ project }}" \
        -scheme "{{ app_scheme }}" \
        -destination "$destination" \
        -derivedDataPath "{{ derived_data }}" \
        "${signing[@]}"

# Build and run the full app test scheme on one selected simulator.
test device="iphone" udid="":
    #!/usr/bin/env bash
    export DEVELOPER_DIR="{{ xcode_developer_dir }}"
    device="{{ device }}"; device="${device#device=}"
    udid="{{ udid }}"; udid="${udid#udid=}"
    if [[ -n "$udid" ]]; then target="$udid"; else case "$device" in iphone) target="{{ iphone_udid }}";; ipad) target="{{ ipad_udid }}";; *) echo "Error: device must be iphone or ipad" >&2; exit 2;; esac; fi
    if ! xcrun simctl list devices available -j | TARGET_UDID="$target" python3 -c 'import json, os, sys; target=os.environ["TARGET_UDID"]; data=json.load(sys.stdin); sys.exit(0 if any(d.get("udid")==target and d.get("isAvailable", True) for ds in data.get("devices", {}).values() for d in ds) else 1)'; then
        echo "Error: app tests require an available simulator: $target" >&2
        exit 1
    fi
    xcrun simctl boot "$target" 2>/dev/null || true
    xcrun simctl bootstatus "$target" -b
    mkdir -p "{{ derived_data }}" tmp/e2e
    result="tmp/e2e/$(date -u +%Y%m%dT%H%M%SZ)-{{ device }}-tests-$$.xcresult"
    destination="platform=iOS Simulator,id=$target"
    xcodegen generate --spec project.yml >/dev/null
    xcodebuild build-for-testing -project "{{ project }}" -scheme "{{ test_scheme }}" -destination "$destination" -derivedDataPath "{{ derived_data }}" -enableCodeCoverage YES CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED="{{ signing_required }}" CODE_SIGN_IDENTITY="{{ signing_identity }}"
    xcodebuild test-without-building -project "{{ project }}" -scheme "{{ test_scheme }}" -destination "$destination" -derivedDataPath "{{ derived_data }}" -resultBundlePath "$result" -enableCodeCoverage YES
    echo "Result bundle: $result"

# Run one app-test class or method, for example test=ShhAppTests/AppContainerTests.
test-focused test="ShhAppTests/AppContainerTests" device="iphone" udid="":
    #!/usr/bin/env bash
    export DEVELOPER_DIR="{{ xcode_developer_dir }}"
    device="{{ device }}"; device="${device#device=}"
    udid="{{ udid }}"; udid="${udid#udid=}"
    test="{{ test }}"; test="${test#test=}"
    target="$udid"; [[ -n "$target" ]] || case "$device" in iphone) target="{{ iphone_udid }}";; ipad) target="{{ ipad_udid }}";; *) echo "Error: device must be iphone or ipad" >&2; exit 2;; esac
    xcrun simctl boot "$target" 2>/dev/null || true
    xcrun simctl bootstatus "$target" -b
    mkdir -p "{{ derived_data }}" tmp/e2e
    result="tmp/e2e/$(date -u +%Y%m%dT%H%M%SZ)-focused-$$.xcresult"
    xcodegen generate --spec project.yml >/dev/null
    xcodebuild test -project "{{ project }}" -scheme "{{ test_scheme }}" -destination "platform=iOS Simulator,id=$target" -derivedDataPath "{{ derived_data }}" -only-testing:"$test" -resultBundlePath "$result" -enableCodeCoverage YES
    echo "Result bundle: $result"

# CI-equivalent host, generic-device, and iPhone/iPad simulator validation.
ci:
    #!/usr/bin/env bash
    set -euo pipefail
    just unit
    just generate
    export DEVELOPER_DIR="{{ xcode_developer_dir }}"
    mkdir -p "{{ derived_data }}"
    xcodebuild build -project "{{ project }}" -scheme "{{ app_scheme }}" -destination 'generic/platform=iOS' -derivedDataPath "{{ derived_data }}" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
    xcodebuild build -project "{{ project }}" -scheme ShhFileProvider -destination 'generic/platform=iOS' -derivedDataPath "{{ derived_data }}" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
    Tests/verify-app-icon.sh "{{ derived_data }}/Build/Products/Debug-iphoneos/Shh.app"
    just test iphone
    just test ipad

# Build and install on a preset simulator or explicit simulator/device UDID.
deploy device="iphone" udid="":
    #!/usr/bin/env bash
    set -euo pipefail
    export DEVELOPER_DIR="{{ xcode_developer_dir }}"
    device="{{ device }}"; device="${device#device=}"
    udid="{{ udid }}"; udid="${udid#udid=}"
    target="$udid"; [[ -n "$target" ]] || case "$device" in iphone) target="{{ iphone_udid }}";; ipad) target="{{ ipad_udid }}";; *) echo "Error: device must be iphone or ipad" >&2; exit 2;; esac
    just build "$device" "$target"
    simulator_state=$(xcrun simctl list devices -j | TARGET_UDID="$target" python3 -c 'import json, os, sys; target=os.environ["TARGET_UDID"]; data=json.load(sys.stdin); matches=[d for ds in data.get("devices", {}).values() for d in ds if d.get("udid")==target]; sys.exit(1) if not matches else print(("available:" if matches[0].get("isAvailable", True) else "unavailable:") + matches[0].get("state", "Shutdown"))' || true)
    case "$simulator_state" in
        available:*)
            xcrun simctl boot "$target" 2>/dev/null || true
            xcrun simctl bootstatus "$target" -b
            xcrun simctl install "$target" "{{ derived_data }}/Build/Products/Debug-iphonesimulator/Shh.app"
            ;;
        unavailable:*)
            echo "Error: simulator $target is unavailable; choose an available simulator or use a physical-device UDID" >&2
            exit 1
            ;;
        *)
            command -v devicectl >/dev/null 2>&1 || { echo "Error: devicectl is required for physical-device deployment" >&2; exit 1; }
            xcrun devicectl device install app --device "$target" "{{ derived_data }}/Build/Products/Debug-iphoneos/Shh.app"
            ;;
    esac

# Convenience form for a specific simulator or physical-device UDID.
deploy-device udid:
    @just deploy custom "{{ udid }}"

# Launch the already-installed app on exactly one selected device.
launch device="iphone" udid="":
    #!/usr/bin/env bash
    device="{{ device }}"; device="${device#device=}"
    udid="{{ udid }}"; udid="${udid#udid=}"
    target="$udid"; [[ -n "$target" ]] || case "$device" in iphone) target="{{ iphone_udid }}";; ipad) target="{{ ipad_udid }}";; *) echo "Error: device must be iphone or ipad" >&2; exit 2;; esac
    export DEVELOPER_DIR="{{ xcode_developer_dir }}"
    simulator_state=$(xcrun simctl list devices -j | TARGET_UDID="$target" python3 -c 'import json, os, sys; target=os.environ["TARGET_UDID"]; data=json.load(sys.stdin); print(next((d.get("state", "Shutdown") for ds in data.get("devices", {}).values() for d in ds if d.get("udid")==target), ""))' || true)
    if [[ -n "$simulator_state" ]]; then xcrun simctl launch "$target" "{{ bundle_id }}"; else xcrun devicectl device process launch --device "$target" "{{ bundle_id }}"; fi

# Terminate only Shh on the selected simulator; physical-device stop is unsupported.
stop device="iphone" udid="":
    #!/usr/bin/env bash
    device="{{ device }}"; device="${device#device=}"
    udid="{{ udid }}"; udid="${udid#udid=}"
    target="$udid"; [[ -n "$target" ]] || case "$device" in iphone) target="{{ iphone_udid }}";; ipad) target="{{ ipad_udid }}";; *) echo "Error: device must be iphone or ipad" >&2; exit 2;; esac
    export DEVELOPER_DIR="{{ xcode_developer_dir }}"
    xcrun simctl terminate "$target" "{{ bundle_id }}" 2>/dev/null || echo "{{ bundle_id }} was not running"

# Stream Shh logs from one simulator into tmp/e2e; use seconds=0 for Ctrl-C streaming.
logs device="iphone" seconds="0" udid="":
    #!/usr/bin/env bash
    device="{{ device }}"; device="${device#device=}"
    udid="{{ udid }}"; udid="${udid#udid=}"
    target="$udid"; [[ -n "$target" ]] || case "$device" in
    iphone) target="{{ iphone_udid }}";; ipad) target="{{ ipad_udid }}";; *) echo "Error: device must be iphone or ipad" >&2; exit 2;; esac
    export DEVELOPER_DIR="{{ xcode_developer_dir }}"
    mkdir -p tmp/e2e
    seconds="{{ seconds }}"; seconds="${seconds#seconds=}"
    output="tmp/e2e/$(date -u +%Y%m%dT%H%M%SZ)-$device-app-$$.log"
    if [[ "$seconds" == "0" ]]; then xcrun simctl spawn "$target" log stream --style compact --predicate 'process == "Shh"' 2>&1 | tee "$output"; else (xcrun simctl spawn "$target" log stream --style compact --predicate 'process == "Shh"' >"$output" 2>&1 & pid=$!; sleep "$seconds"; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true); cat "$output"; fi
    echo "Application log: $output"

# Capture a screenshot without erasing simulator data or overwriting prior evidence.
screenshot device="iphone" name="launch" udid="":
    #!/usr/bin/env bash
    device="{{ device }}"; device="${device#device=}"
    udid="{{ udid }}"; udid="${udid#udid=}"
    name="{{ name }}"; name="${name#name=}"
    target="$udid"; [[ -n "$target" ]] || case "$device" in iphone) target="{{ iphone_udid }}";; ipad) target="{{ ipad_udid }}";; *) echo "Error: device must be iphone or ipad" >&2; exit 2;; esac
    export DEVELOPER_DIR="{{ xcode_developer_dir }}"
    mkdir -p tmp/e2e
    output="tmp/e2e/$(date -u +%Y%m%dT%H%M%SZ)-$device-$name-$$.png"
    xcrun simctl io "$target" screenshot "$output"
    echo "Screenshot: $output"

# Remove only the selected regenerable DerivedData directory.
clean:
    #!/usr/bin/env bash
    case "{{ derived_data }}" in
        "$PWD"/build/*|build/*|"$PWD"/tmp/e2e/*|tmp/e2e/*) ;;
        *) echo "Error: refusing to clean outside build/ or tmp/e2e/: {{ derived_data }}" >&2; exit 2 ;;
    esac
    rm -rf -- "{{ derived_data }}"
    echo "Removed regenerable build products: {{ derived_data }}"
