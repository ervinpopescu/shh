#!/bin/bash
# Keep required GitHub status contexts present on every pull request.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$repo_root/.github/workflows/ci.yml"

ruby -ryaml -e '
workflow = YAML.load_file(ARGV.fetch(0))
jobs = workflow.fetch("jobs")

core = jobs.fetch("core-build-and-test")
simulators = jobs.fetch("simulator-tests")

abort("core build job must not be conditionally skipped") if core.key?("if")
abort("simulator test job must not be conditionally skipped") if simulators.key?("if")
abort("core build job has an unexpected name") unless core["name"] == "Build and Core Tests"
matrix_name = "$" + "{{ matrix.name }}"
abort("simulator job must use matrix names") unless simulators["name"] == matrix_name

entries = simulators.fetch("strategy").fetch("matrix").fetch("include")
names = entries.map { |entry| entry.fetch("name") }
expected = ["iPhone Simulator Tests", "iPad Simulator Tests"]
abort("simulator matrix must define exactly iPhone and iPad contexts") unless names == expected
' "$workflow"

echo "Required CI contexts are unconditional and simulator contexts are exact"
