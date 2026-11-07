# bash_config
Repository for bash aliases, functions, and dotfiles.

## Structure
- `aliases/` one alias per file
- `functions/` one function per file
- `dotfiles/` tracked dotfiles to be symlinked or sourced

## Install
Run `./install.py` to symlink aliases and functions into `~/.bash_aliases/` and
`~/.bash_functions/`, then add a loader snippet to `~/.bashrc`.

## GitHub Accounts

Run one command as any GitHub account already stored by GitHub CLI:

```sh
github_as <username> <command> [arguments...]
```

Install `gh` and log into each desired github.com account with
`gh auth login --hostname github.com`. For Git over HTTPS, configure GitHub CLI
as the credential helper once:

```sh
gh auth setup-git --hostname github.com
```

After running this repository's installer and opening a new Bash shell, replace
the example usernames and repository with your own:

```sh
github_as alice git clone https://github.com/alice/project.git
github_as alice git push
github_as bob gh pr list
```

The helper selects the account's stored token and sets `GH_TOKEN` for the command
and its descendants. It leaves your shell's environment and GitHub CLI's shared
active account unchanged, so later unwrapped commands keep their usual account.
Arguments, input, output, and the command's exit status pass through. Missing
credentials stop execution with an error; the helper never logs in or switches
accounts automatically.

Authentication applies to `gh` and HTTPS Git commands using its credential helper.
It does not select SSH keys, change Git commit names or emails, or support GitHub
Enterprise hosts. Pass a command and its arguments, not a quoted command string;
shell aliases and pipeline syntax are not expanded by the helper.

## VirtualBox Guest Additions

From a terminal inside an X11 guest desktop, restart the installed VirtualBox guest
service and all desktop clients except drag and drop with:

```sh
restart_vbox
```

The function discovers the supported client modes from
`/etc/X11/Xsession.d/98vboxadd-xclient`, explicitly excludes `--draganddrop` and the
combined `--wayland` client, stops only the current user's `VBoxClient` processes, and
removes stale `.vboxclient-*.pid` files before restarting the remaining modes. Run it
as the desktop user; it invokes `sudo` only for the system service restart. A root X11
desktop session is also supported. Non-VirtualBox systems are a successful no-op.

## NetExec SMB Results

Display the SMB hosts where NetExec recorded a successful authentication, including
the detected operating system, domain, username, stored credential, and whether the
credential had administrative access:

```sh
nxc_smb_successes
```

The function reads the active workspace from `~/.nxc/nxc.conf`. Pass a workspace name
to inspect it directly:

```sh
nxc_smb_successes assessment-name
```

It honors `NXC_PATH` and opens the workspace's `smb.db` read-only. Results include all
successful SMB authentications stored in that workspace, so use a dedicated NetExec
workspace when a report must represent one credential test. The report prints stored
passwords or hashes directly to the terminal; handle its output as sensitive data.
