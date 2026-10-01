#!/usr/bin/env bash
# Validate that the distributable's declared third-party inventory stays empty.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTICE="$ROOT_DIR/Sources/GitTrees/Resources/Acknowledgements/THIRD_PARTY_NOTICES.txt"
MANIFEST="$ROOT_DIR/Package.swift"
MODEL_DIR="$ROOT_DIR/Sources/GitTreesCore/Resources/CommitIntentModel"

fail() {
    echo "error: OSS policy check failed: $1" >&2
    exit 1
}

[[ -f "$NOTICE" ]] || fail "THIRD_PARTY_NOTICES.txt is missing"
[[ -f "$MANIFEST" ]] || fail "Package.swift is missing"
[[ ! -e "$MODEL_DIR" ]] || fail "the retired commit-intent model is still bundled"
[[ ! -e "$ROOT_DIR/Sources/GitTrees/Resources/Acknowledgements/Apache-2.0.txt" ]] \
    || fail "the retired model's Apache license file is still bundled"

grep -Fq "bundles no third-party code, models or package dependencies" "$NOTICE" \
    || fail "the current empty distributable inventory is not documented"
grep -Fq 'resources: [.copy("Resources/Acknowledgements")]' "$MANIFEST" \
    || fail "the app target no longer packages its acknowledgements"

if grep -REq 'huggingface|all-MiniLM|CommitIntentModel' \
    "$ROOT_DIR/Package.swift" "$ROOT_DIR/README.md" "$ROOT_DIR/OSS_POLICY.md" \
    "$ROOT_DIR/Sources"; then
    fail "a retired model or attribution reference remains in distributable sources"
fi

# GitTrees currently ships without external Swift package dependencies. A new
# package must be deliberately reviewed and this policy updated in the same PR.
if grep -Eq '\.package[[:space:]]*\(' "$MANIFEST"; then
    fail "Package.swift declares an external package not covered by the current no-dependency policy"
fi

echo "OSS policy check passed: no third-party model or external Swift package is bundled."
