#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"
BUILD_ARGS=()
if [[ -n "${TMUXHUB_SCRATCH_PATH:-}" ]]; then
    BUILD_ARGS+=(--scratch-path "$TMUXHUB_SCRATCH_PATH")
fi
/usr/bin/swift build "${BUILD_ARGS[@]}" --target TmuxHubCore
BIN_DIR="$(/usr/bin/swift build "${BUILD_ARGS[@]}" --show-bin-path)"

/usr/bin/python3 - "$PROJECT_ROOT" "$BIN_DIR" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import tempfile

project, build = map(Path, sys.argv[1:])
with tempfile.TemporaryDirectory(prefix="tmuxhub-hpc-billing-model-") as directory:
    output_map = json.loads((build / "TmuxHubCore.build/output-file-map.json").read_text())
    objects = [entry["object"] for entry in output_map.values() if "object" in entry]
    executable = Path(directory) / "HPCBillingModelHarness"
    subprocess.run([
        "/usr/bin/swiftc", "-swift-version", "6", "-parse-as-library",
        "-I", str(build / "Modules"),
        str(project / "Sources/TmuxHubApp/HPC2PlatformModel.swift"),
        str(project / "Tests/HPCBillingModelHarness.swift"),
        *objects, "-framework", "AppKit", "-framework", "Security",
        "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)
PY
