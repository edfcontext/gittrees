#!/usr/bin/env bash
# Run the same first-party Semgrep rules used by the app as a blocking CI check.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEMGREP_BIN="${SEMGREP_PATH:-$(command -v semgrep || true)}"

if [[ -z "$SEMGREP_BIN" || ! -x "$SEMGREP_BIN" ]]; then
    echo "error: Semgrep is not installed or SEMGREP_PATH is not executable." >&2
    exit 2
fi

STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gittrees-semgrep.XXXXXX")"
trap 'rm -rf "$STATE_DIR"' EXIT
export SEMGREP_SETTINGS_FILE="$STATE_DIR/settings.yml"
export SEMGREP_LOG_FILE="$STATE_DIR/semgrep.log"
export SEMGREP_SEND_METRICS=off
export SEMGREP_ENABLE_VERSION_CHECK=0
export NO_COLOR=1

cd "$ROOT_DIR"
"$SEMGREP_BIN" scan \
    --config Sources/GitTreesCore/Resources/SecurityRules/baseline.yml \
    --oss-only \
    --error \
    --metrics=off \
    --disable-version-check \
    --no-autofix \
    --no-rewrite-rule-ids \
    --timeout=5 \
    --max-target-bytes=1000000 \
    --jobs=2 \
    --exclude .build \
    --exclude .git \
    --exclude node_modules \
    --exclude '.venv*' \
    --exclude vendor \
    --exclude '*.mlpackage' \
    -- .
