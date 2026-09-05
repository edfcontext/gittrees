# GitTrees

A worktree-first Git client for macOS, built with Swift and SwiftUI.

GitTrees treats worktrees as first-class objects. Every worktree of a repository is
shown together with the branch it has checked out, where it lives on disk, and whether
it is dirty — so multiple checkouts of one repository never look like unrelated
repositories.

It is intentionally narrower than SourceTree or GitKraken: open a repository, see its
worktrees and branches, work in one of them, commit, and sync with a remote.

## Git is the source of truth

There is no Git implementation here, and no libgit2 or JGit. Every operation runs the
installed `git` binary through Foundation's `Process`, with arguments passed as an array:

```
SwiftUI views
  → observable view models (RepositoryService, PreferencesService)
    → GitClient            builds argument vectors
      → GitProcessRunner   Foundation Process
        → /usr/bin/git
```

No shell is ever involved — no `sh -c`, no command strings — so paths, branch names and
lock reasons containing spaces, quotes or glob characters need no escaping and cannot be
reinterpreted as syntax.

Machine-readable output is used wherever Git offers it:

| Purpose  | Command |
| -------- | ------- |
| Worktrees | `git worktree list --porcelain -z` |
| Status    | `git status --porcelain=v2 -z --branch --untracked-files=all` |
| Branches  | `git for-each-ref --format=…%00…` (`%00` is `for-each-ref`'s literal NUL) |
| History   | `git log -z --format=…%x00…` |

Hooks and Git configuration are left alone: commits run without `--no-verify`, and the
process inherits the user's environment, so credential helpers and `pre-commit` hooks
behave exactly as they do on the command line.

## Features

- **Repositories** — open any directory inside a repository with a native panel
  (⌘O); a linked worktree resolves to the repository it belongs to. Choosing a folder
  that is not yet a repository offers to `git init` it in place, leaving anything
  already there untouched. Recents are remembered and the last repository is reopened
  at launch.
- **Worktrees** — path, branch, HEAD, detached, locked and prunable state. Create from
  an existing branch or with a new branch (`git worktree add -b`), lock/unlock, prune
  stale metadata, and remove.
- **Branches** — local and (optionally) remote branches, upstream tracking with
  ahead/behind counts. A filled indicator means the branch has a live worktree; clicking
  it selects that worktree instead of attempting a checkout Git would refuse. A branch
  with no worktree offers *Create Worktree* or *Checkout in Current Worktree*.
- **Changes** — staged/unstaged/conflicted file lists, whole-file staging, a monospaced
  unified diff (working tree or index), and a commit editor.
- **Remotes** — fetch, pull and push against a chosen remote, with `--set-upstream`
  offered for a branch that has never been pushed. Git's stdout and stderr are shown
  verbatim.
- **Commit identity** — shows who a commit would be authored as and where that came
  from, and can pin an identity on the repository. See below.
- **Workspace** — open a worktree in Finder, Terminal, IntelliJ IDEA, VS Code or Cursor
  via `NSWorkspace`; the preferred IDE is stored in Settings.

### Safe removal

A worktree with local changes is never removed by default. GitTrees runs `git status`
first and, if anything would be lost, shows what it found and requires an explicit
opt-in before passing `--force`.

### Choosing a remote

A picker appears beside Fetch/Pull/Push once a repository has more than one remote, and
the choice is remembered per repository.

- **Automatic** (the default) is Git's own behaviour: `git fetch --all`, and bare
  `git pull` / `git push` that follow each branch's tracking configuration.
- **Naming a remote** passes it explicitly — `git fetch <remote>`, `git pull <remote>`,
  `git push <remote>` — and is the remote a new branch is published to.

Publishing a branch resolves its remote in order: the explicit choice, then the remote
the branch already tracks, then `origin`, then the only remote there is. If a repository
has no remotes at all, publishing is refused with an explanation rather than failing
against a remote that does not exist.

### Commit identity

The commit bar shows the identity a commit would carry (`as Dev <dev@example.com>`), and
Commit is disabled with a warning when `user.name` or `user.email` is missing — rather
than letting Git reject the commit after the message has been written. Branch Info also
reports whether the identity is set on the repository or inherited from your global
configuration.

Settings can pin an identity with `git config --local`. That config lives in the shared
git directory, so it applies to **every worktree of the repository** — the UI says so,
because with several worktrees open that is easy to get wrong. Your global
`~/.gitconfig` is never modified, and *Use Global Identity* clears the pin.

### New worktree paths

New worktrees are suggested under a per-repository worktree root, with conventional
prefixes (`feature/`, `bugfix/`, `fix/`, `chore/`, …) stripped from the directory name:

```
Repository:    ~/Development/nalcus/summit
Worktree root: ~/Development/nalcus/worktrees/summit
Branch:        feature/zpl-templates
Suggested:     ~/Development/nalcus/worktrees/summit/zpl-templates
```

The suggestion updates as you type and can be overridden; the root is configurable per
repository in Settings.

## Not in this version

GitHub/GitLab integration, pull requests, issues, interactive rebase, merge editor,
hunk or line staging, submodules, LFS, SSH keys, credential UI, cloning, signing
configuration, bisect, reflog, stash, blame, tags, and commit-graph rendering. The
architecture leaves room for these; the scope deliberately does not include them.

## Building

Requires macOS 14+ and the Xcode command line tools.

```bash
swift build
swift test
```

To produce a runnable `.app` bundle (SwiftPM emits a bare executable; macOS needs a
bundle with an `Info.plist` for a Dock icon, menu bar and open panels):

```bash
./Scripts/build-app.sh
```

The bundle is written to `.build/GitTrees.app`. Pass `debug` to bundle a debug build.
The icon is taken from `Resources/AppIcon.png` if present, otherwise `image.png` in the
project root, and converted to an `.icns` with `sips` and `iconutil`.

## Layout

```
Sources/
  GitTreesCore/          no SwiftUI — usable from tests
    Models/              Repository, Worktree, Branch, FileChange, CommitSummary
    Git/                 GitClient, GitCommand, GitProcessRunner, GitError,
                         WorktreeParser, StatusParser, BranchParser
    Services/            RepositoryService, PreferencesService,
                         WorkspaceLauncher, WorktreePathSuggester
  GitTrees/              the application
    App/                 GitTreesApp, menu commands, window configuration
    Views/               MainView, RepositorySidebar, WorktreeList, BranchList,
                         WorktreeDetailView, ChangesView, DiffView, CommitView,
                         HistoryView, BranchInfoView, NewWorktreeSheet,
                         RemoveWorktreeSheet, PreferencesView
Tests/GitTreesCoreTests/
```

## Tests

Two layers:

- **Parser suites** run against fixtures captured verbatim from real repositories
  (`git worktree list --porcelain -z | tr '\0' '|'`), covering the main worktree,
  linked worktrees, detached/locked/prunable state, paths with spaces, non-ASCII branch
  names, and modified/staged/untracked/renamed/deleted/conflicted status entries.
- **Integration suite** drives the real `git` binary in throwaway repositories, which is
  the only way to prove the argument vectors are ones Git accepts: `git init` on a
  folder with existing content, worktree lifecycle,
  branch-already-checked-out refusal, pruning, staging on an unborn HEAD, diffs, commits,
  hook enforcement, merge conflicts, the dirty-removal guard, identity round-trips across
  linked worktrees, and publishing a branch to a remote that is deliberately not called
  `origin`.

## Notes

- Settings can point at a different `git` (for example `/opt/homebrew/bin/git`).
- `GIT_TERMINAL_PROMPT=0` is set so a missing credential fails fast instead of hanging
  on a prompt that has no terminal to appear on.
- Concurrency: Git runs off the main actor; all UI state is main-actor isolated. A
  destructive operation claims its worktree first, so two cannot overlap on one path.
- A working directory that has vanished is rejected before `Process.run()`, which
  otherwise raises an Objective-C exception that Swift cannot catch — the case a worktree
  deleted from under the application would hit.
- SwiftUI presents only one of several same-kind presentation modifiers attached to a
  single view. Every modal in the window therefore goes through one `.sheet(item:)`
  driven by `ActiveSheet`, and each `.fileImporter` is attached to the button that opens
  it, rather than stacking modifiers and having all but the last silently do nothing.
