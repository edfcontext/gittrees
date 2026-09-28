# Open-source software policy

GitTrees may ship third-party code or assets only after their origin, license and
required notices have been reviewed. The CI policy permits these licenses for new
dependency changes:

- 0BSD
- Apache-2.0
- BSD-2-Clause
- BSD-3-Clause
- ISC
- MIT
- MIT-0
- Zlib

Dependencies with other, missing or unrecognized licenses require an explicit policy
change and review. Pull requests also fail when a newly introduced dependency has a
known vulnerability of moderate severity or higher.

## Current distributable inventory

GitTrees has no external Swift package dependencies. The distributable includes the
modified `sentence-transformers/all-MiniLM-L6-v2` model and tokenizer assets under
Apache-2.0. Its attribution and full license are packaged from
`Sources/GitTrees/Resources/Acknowledgements`.

Development-only system tools such as Git, GitHub CLI and Semgrep are invoked from the
user or CI environment and are not redistributed in `GitTrees.app`.

Run `Scripts/check-oss-policy.sh` locally after changing dependencies, model assets,
acknowledgements or packaging. Pull requests additionally use GitHub's dependency
review to enforce the license allowlist and vulnerability threshold.
