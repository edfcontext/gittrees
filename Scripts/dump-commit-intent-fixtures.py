#!/usr/bin/env python3
"""Dump Python normalize/render goldens for Swift parity tests."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = Path("/Users/user/Dev/AI-Projects/gittrees-model")
sys.path.insert(0, str(MODEL))

from data.extract_symbols import extract_symbols  # noqa: E402
from data.label_with_llm import _infer_object  # noqa: E402
from data.normalize_diff import normalize_diff  # noqa: E402
from runtime.renderer import RenderStyle, render  # noqa: E402

SWIFT = """diff --git a/Sources/Git/WorktreeManager.swift b/Sources/Git/WorktreeManager.swift
index 1..2 100644
--- a/Sources/Git/WorktreeManager.swift
+++ b/Sources/Git/WorktreeManager.swift
@@ -1,3 +1,4 @@
-    func deleteWorktree(_ w: Worktree) {
+    func deleteWorktree(_ w: Worktree, force: Bool) {
+        removeBranch(w.branch)
     }
diff --git a/pkg/package-lock.json b/pkg/package-lock.json
--- a/pkg/package-lock.json
+++ b/pkg/package-lock.json
@@ -1 +1 @@
-old
+lockfile noise
"""

DEMO = """diff --git a/Sources/Git/WorktreeManager.swift b/Sources/Git/WorktreeManager.swift
--- a/Sources/Git/WorktreeManager.swift
+++ b/Sources/Git/WorktreeManager.swift
@@ -10,7 +10,9 @@ final class WorktreeManager {
-    func deleteWorktree(_ w: Worktree) {
+    func deleteWorktree(_ w: Worktree, force: Bool) throws {
+        guard !w.isDirty || force else { throw GitError.dirty }
+        removeBranch(w.branch)
         refreshWorktrees()
     }
"""

MULTILANG = (
    "+ def parse_commit(x):\n"
    "+ class BranchView:\n"
    "+ func RefreshWorktrees() error {\n"
    "+ export const loadStatus = async () => {"
)

BIG = (
    "diff --git a/x.py b/x.py\n--- a/x.py\n+++ b/x.py\n@@ -1 +1 @@\n"
    + "\n".join(f"+line number {i} with words" for i in range(500))
)

fixtures = {
    "swift_diff": SWIFT,
    "swift_normalized": normalize_diff(SWIFT),
    "swift_symbols": extract_symbols(SWIFT),
    "swift_object": _infer_object(
        {
            "diff": SWIFT,
            "files": ["Sources/Git/WorktreeManager.swift", "pkg/package-lock.json"],
        }
    ),
    "demo_diff": DEMO,
    "demo_normalized": normalize_diff(DEMO),
    "demo_symbols": extract_symbols(DEMO),
    "demo_object": _infer_object(
        {"diff": DEMO, "files": ["Sources/Git/WorktreeManager.swift"]}
    ),
    "multilang_symbols": extract_symbols(MULTILANG),
    "if_symbols": extract_symbols("+ if (x) {"),
    "truncated": normalize_diff(BIG, max_words=60),
    "renders": {
        "fix_worktree": render({"type": "FIX", "action": "FIX", "scope": "WORKTREE"}),
        "add_branch": render({"type": "FEATURE", "action": "ADD", "scope": "BRANCH"}),
        "update_settings": render(
            {"type": "CONFIG", "action": "UPDATE", "scope": "SETTINGS"}
        ),
        "handle_object": render(
            {"type": "FIX", "action": "HANDLE", "scope": "WORKTREE"},
            "worktree deletion",
        ),
        "conventional": render(
            {"type": "FIX", "action": "HANDLE", "scope": "WORKTREE"},
            "worktree deletion",
            RenderStyle.CONVENTIONAL,
        ),
        "general_no_object": render(
            {"type": "REFACTOR", "action": "UPDATE", "scope": "GENERAL"}
        ),
        "add_general": render({"type": "FEATURE", "action": "ADD", "scope": "GENERAL"}),
    },
}

out = ROOT / "Tests/GitTreesCoreTests/Fixtures/commit_intent_goldens.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(fixtures, indent=2, ensure_ascii=False) + "\n")
print(out)
