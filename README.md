# bash_config
Repository for bash aliases, functions, and dotfiles.

## Structure
- `aliases/` one alias per file
- `functions/` one function per file
- `dotfiles/` tracked dotfiles to be symlinked or sourced

## Install
Run `./install.py` to symlink aliases and functions into `~/.bash_aliases/` and
`~/.bash_functions/`, then add a loader snippet to `~/.bashrc`.

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
the detected operating system and whether the credential had administrative access:

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
workspace when a report must represent one credential test.
