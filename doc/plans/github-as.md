# Plan: Run a command as a selected GitHub account

## Summary

Add `github_as <username> <command> [arguments...]` to run one command with the
stored github.com credentials for any requested account. Use GitHub CLI's
account-specific token lookup and a subprocess environment so the helper does
not switch the shared active account or change the calling shell. Deliver one
function, focused tests, and README instructions through the existing installer.

## Problem

GitHub CLI's active account is shared across terminals. A private repository can
appear unavailable when the active account lacks access, even though the correct
account is already logged in. Manually retrieving a selected account's token for
each command is cumbersome. The repository has no existing GitHub account helper
or callers to migrate.

## Scope

In scope:

- **Core correctness:** select any locally authenticated github.com username,
  confine credentials to the invoked command and its descendants, preserve
  arguments and exit status, and stop clearly when credentials are unavailable.
- **Required integration:** add behavior tests and document prerequisites and
  examples in the README. Use existing function discovery and export behavior.

Out of scope:

- Automatic selection from repository ownership, account aliases, interactive
  account pickers, and changes to the shared active account.
- SSH key selection, remote URL rewriting, Git author name/email configuration,
  GitHub Enterprise hosts, and other Git hosting providers.
- Logging in, managing tokens or scopes, adding credential caches, automatically
  configuring Git, or implementing authentication for arbitrary third-party tools.
- Installer redesign, completions, unrelated shell cleanup, and additional plans.

## Design

Repository inspection at `409633a` confirms that `install.py` discovers
`functions/*.sh`, links each file, sources it, and exports its matching function
name. Follow the existing one-function-per-file convention and Python `unittest`
tests that invoke Bash with temporary command stubs. No installer change is needed.

The simplification pass keeps ownership in GitHub CLI: use its stored credentials
directly, with no account registry, configuration-file parsing, API preflight,
switch-and-restore logic, or new shared abstraction. Token availability is the
local selection check; the requested command reports expired-token, permission,
and network failures. One plan covers this single behavior and its validation.

The function contract is:

1. Accept a nonempty username and a nonempty command, followed by arbitrary
   arguments. Missing inputs produce usage on stderr and status 2. Do not
   hardcode usernames or impose a separate username-validation grammar.
2. Retain the conventional `github_as() { ... }` declaration and execute its work
   inside a subshell. Disable shell xtrace inside that subshell before handling
   tokens; the parent's environment and shell options must remain intact.
3. Require `gh` on PATH. Capture the output of
   `gh auth token --hostname github.com --user "$github_as_user"`, checking its
   status separately from variable declaration. Explicit `--user` selects stored
   credentials for that account, independently of the active account and ambient
   tokens. Preserve `GH_CONFIG_DIR` so users' existing credential stores work.
4. If `gh` is unavailable, lookup fails, or its output is empty, emit a clear
   error on stderr and return status 1 without invoking the command. A missing
   account error should point to `gh auth login --hostname github.com`; do not
   initiate login or fall back to another account.
5. Export the captured value as `GH_TOKEN` only inside the subshell, then invoke
   the remaining `"$@"` once, without `eval` or command-string reconstruction.
   This overrides an inherited `GH_TOKEN`; GitHub CLI gives it precedence over
   `GITHUB_TOKEN`. Forward stdin, stdout, stderr, and the command's exit status,
   including normal shell failures such as a missing command. Shell aliases and
   pipeline syntax are not parsed as command arguments.
6. The helper must not print tokens, embed them in command arguments, write them
   to files, or run `gh auth switch`, `gh auth login`, or `gh auth setup-git`.
   Secret handling belongs to the helper; output and side effects deliberately
   produced by the user's command remain that command's responsibility.

Git itself does not consume `GH_TOKEN`. Git over HTTPS is supported when GitHub
CLI is configured as the github.com credential helper, using the user's one-time
setup command `gh auth setup-git --hostname github.com`. Document that prerequisite
alongside logging into each desired account with `gh auth login --hostname
github.com`. Use explicit HTTPS clone URLs in examples; existing SSH remotes are
outside this helper's authentication path. Do not add Git-specific dispatch or
automatic configuration changes to the function.

The README examples should use placeholder accounts such as `alice` and `bob`
for cloning, pushing, and `gh pr list`. Explain that the selected token applies to
`gh` and Git's configured `gh` credential helper, and does not set commit authorship
or change the account used by later unwrapped commands.

Authoritative references: [account-specific token lookup](https://cli.github.com/manual/gh_auth_token),
[environment token precedence](https://cli.github.com/manual/gh_help_environment),
and [Git credential setup](https://cli.github.com/manual/gh_auth_setup-git).
The installed GitHub CLI 2.45.0 exposes the required flags; its
[token selection implementation](https://github.com/cli/cli/blob/v2.45.0/pkg/cmd/auth/token/token.go)
uses `TokenForUser` when `--user` is provided. No version-specific fallback is needed.

## Affected Components

- `functions/github_as.sh` (new): the public helper and its command-local
  authentication and failure behavior.
- `tests/test_github_as.py` (new): isolated behavior tests using fake credentials
  and temporary commands, following the existing `unittest` approach.
- `README.md`: prerequisites, usage, HTTPS requirement, and authentication versus
  commit identity. Existing installation instructions remain authoritative.

## Implementation Sequence

1. Recheck repository instructions and search for any newly added `github_as`
   callers or definitions before implementing. Add the function using the
   existing loading/export convention.
2. Add focused tests for the contract below, including one installer smoke test
   using a temporary home directory. Keep all credentials synthetic and all
   external command interactions local.
3. Add the README usage section, run the focused and existing checks, and follow
   repository instructions to commit and push only this feature's changes.

## Validation

Tests should prove:

- Two arbitrary account names select distinct fake tokens with the required
  github.com and username arguments, even with a different active account and
  preexisting `GH_TOKEN` and `GITHUB_TOKEN` values.
- The command runs once with exact argument boundaries, including spaces, empty
  arguments, and shell metacharacters; stdin and output pass through and a
  representative nonzero exit status is preserved.
- Missing inputs, missing `gh`, failed lookup, and empty lookup output produce
  useful errors and never invoke the target command. No login, account switch,
  configuration write, or fallback is attempted.
- Parent token variables remain unchanged or unset as appropriate after both
  success and failure. The helper does not expose the fake secret on stdout,
  stderr, or xtrace when the target itself does not print it; parent xtrace state
  is preserved. Exercise ordinary calls under `set -u` as existing tests do.
- Running the unchanged installer against a temporary home links
  `github_as.sh`, and its loader makes the function available in a Bash child
  process. No production home directory is modified by tests.

Run these commands from the repository after implementation:

```sh
bash -n functions/github_as.sh
python3 -m unittest discover -s tests -p 'test_github_as.py' -v
python3 -m unittest discover -s tests -v
git diff --check
```

The existing full suite requires `sqlite3` as well as Python and Bash. Live
account access is not a prerequisite for automated validation. Verify the
documented Git prerequisite against `gh auth setup-git --help`; do not build a
separate credential-helper implementation or network fixture for these tests.

## Success Criteria

- Any user with a stored github.com account can use the documented syntax for
  `gh` and properly configured HTTPS Git commands without embedding account
  names or secrets in the function.
- Selecting one account never silently executes with another account's token;
  unavailable credentials prevent execution.
- Arguments, streams, and exit status pass through, while helper-managed
  credentials and shell-option changes do not persist in the caller.
- Existing installation discovers the function unchanged, focused tests and the
  existing suite pass, and the README states the prerequisites and limits.
