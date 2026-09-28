#!/usr/bin/env bash
# Validate the distributable's current third-party inventory and required notices.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTICE="$ROOT_DIR/Sources/GitTrees/Resources/Acknowledgements/THIRD_PARTY_NOTICES.txt"
LICENSE="$ROOT_DIR/Sources/GitTrees/Resources/Acknowledgements/Apache-2.0.txt"
MANIFEST="$ROOT_DIR/Package.swift"

fail() {
    echo "error: OSS policy check failed: $1" >&2
    exit 1
}

[[ -f "$NOTICE" ]] || fail "THIRD_PARTY_NOTICES.txt is missing"
[[ -f "$LICENSE" ]] || fail "the Apache 2.0 license text is missing"
[[ -f "$MANIFEST" ]] || fail "Package.swift is missing"

grep -Fq "sentence-transformers/all-MiniLM-L6-v2" "$NOTICE" \
    || fail "the bundled MiniLM source is not identified in the notice"
grep -Fq "License: Apache License, Version 2.0" "$NOTICE" \
    || fail "the bundled MiniLM license is not identified as Apache 2.0"
grep -Fq "The included model is a modified derivative" "$NOTICE" \
    || fail "the bundled model modification notice is missing"
grep -Fq "Apache License" "$LICENSE" \
    || fail "the Apache license file is not recognizable"
grep -Fq "Version 2.0, January 2004" "$LICENSE" \
    || fail "the Apache 2.0 license version is missing"
grep -Fq 'resources: [.copy("Resources/Acknowledgements")]' "$MANIFEST" \
    || fail "the app target no longer packages its acknowledgements"

# GitTrees currently ships without external Swift package dependencies. A new
# package must be deliberately reviewed and this policy updated in the same PR.
if grep -Eq '\.package[[:space:]]*\(' "$MANIFEST"; then
    fail "Package.swift declares an external package not covered by the current no-dependency policy"
fi

echo "OSS policy check passed: no external Swift packages; bundled MiniLM notices are present."
