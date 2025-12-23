# bash_config
Repository for bash aliases, functions, and dotfiles.

## Structure
- `aliases/` one alias per file
- `functions/` one function per file
- `dotfiles/` tracked dotfiles to be symlinked or sourced

## Install
Run `./install.sh` to symlink aliases and functions into `~/.bash_aliases/` and
`~/.bash_functions/`, then add a loader snippet to `~/.bashrc`.
