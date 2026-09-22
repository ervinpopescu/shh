#!/bin/bash
# Verify that strict warning settings are scoped to Shh targets and package targets.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
project="$repo_root/Shh.xcodeproj"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if [[ ! -d "$project" ]] && command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec "$repo_root/project.yml" >/dev/null
fi

if ! swift package dump-package --package-path "$repo_root" | jq -e '
  .targets | length > 0 and all(
    (.settings // []) | any(
      .kind.unsafeFlags._0? // [] | index("-warnings-as-errors") != null
    )
  )
' >/dev/null; then
  echo "Package.swift does not enable warnings-as-errors for first-party package targets" >&2
  exit 1
fi

for target in Shh ShhFileProvider ShhCoreTests ShhSSHTests ShhTerminalTests ShhVoiceTests ShhAppTests; do
  settings=$(xcodebuild \
    -project "$project" \
    -target "$target" \
    -destination 'generic/platform=iOS' \
    -showBuildSettings 2>/dev/null)
  grep -Fq 'SWIFT_TREAT_WARNINGS_AS_ERRORS = YES' <<< "$settings" || {
    echo "$target does not expose Swift warnings-as-errors in generated settings" >&2
    exit 1
  }
  grep -Fq 'GCC_TREAT_WARNINGS_AS_ERRORS = YES' <<< "$settings" || {
    echo "$target does not expose Clang warnings-as-errors in generated settings" >&2
    exit 1
  }
done

ruby -ryaml -e '
ci = YAML.load_file(ARGV[0])
jobs = ci["jobs"] || {}
jobs.each do |job_name, job|
  next unless job.is_a?(Hash)
  env = job["env"] || {}
  if env["SWIFT_TREAT_WARNINGS_AS_ERRORS"] == "YES"
    abort("Job #{job_name} applies SWIFT_TREAT_WARNINGS_AS_ERRORS globally")
  end
  (job["steps"] || []).each do |step|
    next unless step.is_a?(Hash)
    step_env = step["env"] || {}
    if step_env["SWIFT_TREAT_WARNINGS_AS_ERRORS"] == "YES"
      abort("Step #{step["name"]} in job #{job_name} applies SWIFT_TREAT_WARNINGS_AS_ERRORS in env")
    end
    run_cmd = step["run"]
    if run_cmd.is_a?(String) && run_cmd.lines.any? { |line| line.strip !~ /^#/ && line =~ /\bSWIFT_TREAT_WARNINGS_AS_ERRORS=YES\b/ }
      abort("Step #{step["name"]} in job #{job_name} applies SWIFT_TREAT_WARNINGS_AS_ERRORS globally in run")
    end
  end
end
' "$repo_root/.github/workflows/ci.yml"

echo "Warning settings are scoped to first-party targets"
