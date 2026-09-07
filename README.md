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
| Commit    | `git log -1 -z --format=…` and `git diff-tree --name-status -z` |

Hooks and Git configuration are left alone: commits run without `--no-verify`, and the
process inherits the user's environment, so credential helpers and `pre-commit` hooks
behave exactly as they do on the command line.

## Features

- **Repositories** — open any directory inside a repository with a native panel
  (⌘O); a linked worktree resolves to the repository it belongs to. **New Repository**
  (⌥⌘N) creates a folder, runs `git init`, and adds a remote in one step. Choosing a folder
  that is not yet a repository offers to `git init` it in place, leaving anything
  already there untouched. Recents are remembered and every open repository window is
  restored at launch. Each window holds one repository: **New Window** (⇧⌘N) opens another,
  and opening a repository while one is already open creates a new window rather than
  replacing it.
- **Worktrees** — path, branch, HEAD, detached, locked and prunable state. Create from
  an existing branch or with a new branch (`git worktree add -b`), lock/unlock, prune
  stale metadata, and remove. The main worktree's branch can be switched with
  `git checkout` — from its header, its context menu, or Repository → Switch Main
  Worktree Branch. A branch already checked out in another worktree is offered but
  disabled; Git would refuse it.
- **Branches** — local and (optionally) remote branches, upstream tracking with
  ahead/behind counts. A filled indicator means the branch has a live worktree; clicking
  it selects that worktree instead of attempting a checkout Git would refuse. A branch
  with no worktree offers *Create Worktree* or *Checkout in Main Worktree*.
- **History** — a flat commit list for the selected worktree. Selecting a commit shows
  its message, the files it changed, and a unified diff of the selected file (`git show`).
- **Changes** — staged/unstaged/conflicted file lists, whole-file staging, a monospaced
  unified diff (working tree or index), and a commit editor. Rows multi-select with the
  ordinary ⌘-click and ⇧-click, and the context menu acts on everything selected — see
  below. Right-click an untracked file to add it (or its folder) to this worktree's
  `.gitignore`, or open **Ignore…** for the rest. Status reloads when the
  window becomes key (returning from an IDE) as well as after GitTrees operations and
  ⌘R.
- **Remotes** — add a remote, and fetch, pull and push against a chosen one, with
  `--set-upstream` offered for a branch that has never been pushed. Git's stdout and
  stderr are shown verbatim.
- **Commit identity** — shows who a commit would be authored as and where that came
  from, and can pin an identity on the repository. See below.
- **Pull requests** — open a pull request for the selected worktree's branch through the
  GitHub CLI (`gh pr create`), and see the one already open for it. See below.
- **Workspace** — open a worktree in Finder, Terminal, IntelliJ IDEA, VS Code or Cursor
  via `NSWorkspace`; the preferred IDE is stored in Settings.

### Selecting changes

The file list is a normal macOS multiple selection: ⌘-click adds and removes rows,
⇧-click extends a range, and the range can cross the Staged and Changes sections.
Right-clicking inside the selection acts on all of it and right-clicking a row outside it
acts on that row alone, leaving the selection untouched. Stage, unstage, ignore and copy
all take however many rows are selected, in one Git invocation and one refresh, and the
menu says how many.

The diff pane shows a diff only for a single selected file; with several selected it says
so rather than showing an arbitrary one of them.

A selection survives a refresh, and follows a file that moves between the two sections —
staging four files keeps the same four rows selected, now in Staged. A path with no
changes left drops out of the selection.

Two details of the identity this rests on are worth stating, because both are easy to get
wrong. A partially staged file is *two* rows showing different diffs, so a row is
identified by its path **and** which side of the index it is on — identifying rows by the
file alone gives the list two rows with one identity and it then highlights whichever it
likes. And clicking a row that is already part of a multiple selection does not collapse
the selection onto it: SwiftUI's `List` has no equivalent of AppKit's mouse-up rule, and
the obvious fix — a tap gesture on the row — races the List's own click handling and
breaks plain clicking altogether. Click a row outside the selection, or ⌘-click, to get
back to one file.

### Ignore rules

The context menu on an untracked file can only guess: the file itself, or the one folder
directly above it. **Ignore…** opens a sheet for everything else — and shows what the
rule would hide before it is written.

- **Which rule.** The file, any folder on its path (`src/generated/api`, `src/generated`,
  `src`, chosen from a menu), that folder *wherever it appears* (`node_modules/` rather
  than `/app/vendor/node_modules/`), every file with the same extension, every file with
  the same name, or a pattern typed by hand.
- **Which file.** `.gitignore` is tracked, so a rule written there is committed and
  reaches everyone who clones the repository. `.git/info/exclude` never leaves the
  machine — the right place for a scratch directory or an editor's droppings that only
  you have. Git reads `info/exclude` from the *shared* git directory, so a local rule
  applies to every worktree of the repository; a file placed in a linked worktree's own
  `.git/worktrees/<name>/info/exclude` is simply never read.
- **What it catches.** The sheet lists the untracked files the rule would hide, and says
  so when it would hide none. Rather than reimplementing Git's matching — anchoring,
  `**`, character classes, directory-only rules — it asks Git for the untracked list
  twice, once with the candidate rule added, and reports the difference. Nothing is
  written to the worktree to do it.

Glob metacharacters in a path are escaped, so a file called `file[1].txt` is matched
literally, and a name starting with `#` or `!` is escaped when the pattern is unanchored
and those characters would start a comment or a negation.

### Moving changes into a worktree

Work usually starts in whichever worktree is already open, and only then turns out to
want a branch of its own. **Move Changes to New Worktree…** (⇧⌘M, the Repository menu, or
a worktree's context menu) creates the branch and worktree and carries the uncommitted
work across — *Move* empties the source worktree, *Copy* leaves it as it was. The option
also appears in the New Worktree sheet whenever the current worktree is dirty.

The transfer goes through the stash, because it is the only mechanism that reproduces the
whole working state: staged and unstaged changes kept apart, and untracked files
included. The order is deliberate — stash, create the worktree, apply, and only then drop
the stash entry:

- If the worktree cannot be created, the changes are put straight back and the stash
  entry is dropped, leaving the source exactly as it was.
- If they cannot be applied, the entry is **not** dropped and the error names the stash
  commit that still holds them.
- The new branch starts at the source worktree's own commit by default, which is the
  start point that cannot conflict. Choosing another is allowed, with a warning.

### Safe removal

A worktree with local changes is never removed by default. GitTrees runs `git status`
first and, if anything would be lost, shows what it found and requires an explicit
opt-in before passing `--force`.

### Remotes

**Add Remote…** (Repository menu, the toolbar's remote menu, or the Repository tab) runs
`git remote add <name> <url>`. `origin` is offered as the name for a repository that has
none yet. Renaming, changing a URL and removing a remote are still command-line work —
this exists so a repository created with `git init` here can be connected to something,
which otherwise left Push with nowhere to go.

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
than letting Git reject the commit after the message has been written. The Repository tab
reports whether the identity is set on the repository or inherited from your global
configuration, and can pin one with `git config --local`. That config lives in the shared
git directory, so it applies to **every worktree of the repository** — the UI says so,
because with several worktrees open that is easy to get wrong. Your global
`~/.gitconfig` is never modified, and *Use Global Identity* clears the pin.

### New worktree paths

New worktrees are suggested under a `.worktrees` directory beside the repository, with
conventional prefixes (`feature/`, `bugfix/`, `fix/`, `chore/`, …) stripped from the
directory name:

```
Repository:    ~/Development/nalcus/summit
Worktree root: ~/Development/nalcus/.worktrees
Branch:        feature/zpl-templates
Suggested:     ~/Development/nalcus/.worktrees/zpl-templates
```

The repository name is not a level of its own: repositories sharing a parent share the
`.worktrees` directory, and the branch directory inside it is what names the checkout.

The suggestion updates as you type and can be overridden; the root is configurable per
repository on the Repository tab.

The New Worktree sheet also offers, checked by default, to add the root's directory name
(`.worktrees/`) to `.git/info/exclude` — written only if the worktree is really created,
and only when that line is not already in the file, so the checkbox disappears once it
is. The rule follows whatever the root is actually called, so a repository pointed at a
differently named root gets a rule that matches it. With the default root, which sits
beside the repository and outside its work tree, the rule changes nothing today; it
covers a root configured inside the repository, where Git would otherwise report every
worktree in it as untracked. The sheet says which of the two applies.

### Pull requests (GitHub CLI)

GitTrees drives the [GitHub CLI](https://cli.github.com) rather than talking to the
GitHub API itself — gh already owns authentication, so there are no tokens to manage in
the app. Point Settings → GitHub at the `gh` binary (the common Homebrew and MacPorts
locations are probed by default); the section shows, live, whether gh is installed and
which account it is signed in as.

**Create Pull Request…** (Repository menu, or the toolbar button that appears when the
repository has a GitHub remote) opens a sheet for the selected worktree's branch. The
head is fixed — it is the branch that worktree has checked out — and the sheet runs in
the worktree's directory, so gh sees the right branch as HEAD. You choose the base, edit
a title (prefilled from the last commit) and body, and optionally mark it a draft; it
then runs:

```
gh pr create --title <t> --body <b> --base <base> --head <branch> [--draft]
```

Preconditions are shown up front rather than surfaced as a failure after you have
written a description: gh must be installed and signed in, the repository needs a GitHub
remote, and the branch must have been pushed. When a pull request is already open for the
branch, the sheet shows it instead, with **Open in Browser** (`gh pr view --web`).

Signing in (`gh auth login`) and enterprise-host configuration stay in the terminal,
where gh's own interactive flow belongs; GitTrees never runs interactive gh commands.

## Not in this version

GitLab integration, issue tracking, PR review and merge (only *creating* a pull request
is supported, via the GitHub CLI), interactive rebase, merge editor,
hunk or line staging, submodules, LFS, SSH keys, credential UI, cloning, signing
configuration, bisect, reflog, blame, tags, and commit-graph rendering. There is no stash
*interface* either — no list, no manual push and pop; the stash is used internally, as
the transport that moves uncommitted changes into a new worktree. The
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
    Models/              Repository, Worktree, Branch, FileChange, CommitSummary,
                         CommitDetail
    Git/                 GitClient, GitCommand, GitProcessRunner, GitError,
                         WorktreeParser, StatusParser, BranchParser,
                         CommitDetailParser
    Services/            RepositoryService, PreferencesService,
                         WorkspaceLauncher, WorktreePathSuggester
  GitTrees/              the application
    App/                 GitTreesApp, menu commands, window configuration
    Views/               MainView, RepositorySidebar, WorktreeList, BranchList,
                         WorktreeDetailView, ChangesView, DiffView, CommitView,
                         HistoryView, BranchInfoView, NewWorktreeSheet,
                         NewWorkspaceSheet, RemoveWorktreeSheet, IgnoreSheet,
                         PreferencesView
Tests/GitTreesCoreTests/
```

## Tests

Two layers:

- **Selection suite** covers the identity the Changes list selects by: a partially staged
  file as two rows, conflicted and untracked entries on the working-tree side only, and a
  selection following a file across the index or dropping out when the path is committed.
- **Parser suites** run against fixtures captured verbatim from real repositories
  (`git worktree list --porcelain -z | tr '\0' '|'`), covering the main worktree,
  linked worktrees, detached/locked/prunable state, paths with spaces, non-ASCII branch
  names, and modified/staged/untracked/renamed/deleted/conflicted status entries,
  plus commit metadata and `name-status -z` file lists.
- **Integration suite** drives the real `git` binary in throwaway repositories, which is
  the only way to prove the argument vectors are ones Git accepts: `git init` on a
  folder with existing content, creating a new workspace folder with `git init` and a
  remote, worktree lifecycle,
  branch-already-checked-out refusal, switching the main worktree's branch, pruning, staging on an unborn HEAD, diffs, commits,
  ignoring an untracked path via `.gitignore`, a local exclude proving Git reads it from
  the shared git directory, previewing a rule without writing anything, and the stash
  round trip that carries staged, unstaged and untracked work into a new worktree,
  inspecting a commit's files and patch (including the root commit and a rename),
  hook enforcement, merge conflicts, the dirty-removal guard, identity round-trips across
  linked worktrees, adding remotes, publishing a branch to a remote that is deliberately
  not called `origin`, and the whole init → commit → add remote → publish path end to end.
  The GitHub CLI layer is covered by a mock runner (exact `gh` argument vectors, and
  decoding gh's real `pr view --json` payload) plus, where gh is installed, live checks
  that `auth` and a `pr view` lookup behave and never crash.
- **Service suite** drives `RepositoryService` itself against real repositories, for the
  creation paths that are a sequence rather than a command: moving changes into a worktree
  stashes, creates, applies and drops, and the ordering is the whole safety story. It
  covers the move, the copy, the plain creation that leaves the changes alone, the
  failure that has to put them back, and the worktree-root ignore rule — written once,
  and not at all when the worktree was never created.

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
