#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path


def link_dir(src_dir: Path, dst_dir: Path) -> None:
    dst_dir.mkdir(parents=True, exist_ok=True)
    for file in src_dir.glob("*.sh"):
        target = dst_dir / file.name
        if target.is_symlink() or target.exists():
            target.unlink()
        target.symlink_to(file)


def ensure_snippet(rc_file: Path, marker: str, snippet: str) -> None:
    rc_file.parent.mkdir(parents=True, exist_ok=True)
    rc_file.touch(exist_ok=True)
    content = rc_file.read_text()
    if marker in content:
        return
    rc_file.write_text(content.rstrip("\n") + "\n\n" + snippet.strip() + "\n")


def main() -> None:
    repo_dir = Path(__file__).resolve().parent
    aliases_dir = Path.home() / ".bash_aliases"
    functions_dir = Path.home() / ".bash_functions"

    link_dir(repo_dir / "aliases", aliases_dir)
    link_dir(repo_dir / "functions", functions_dir)

    bashrc_marker = "# bash_config loader"
    bashrc_snippet = f"""
{bashrc_marker}
if [ -d "$HOME/.bash_aliases" ]; then
    for file in "$HOME/.bash_aliases"/*.sh; do
        [ -e "$file" ] || continue
        . "$file"
    done
fi

if [ -d "$HOME/.bash_functions" ]; then
    for file in "$HOME/.bash_functions"/*.sh; do
        [ -e "$file" ] || continue
        . "$file"
    done
fi
"""
    ensure_snippet(Path.home() / ".bashrc", bashrc_marker, bashrc_snippet)

    bash_profile = Path.home() / ".bash_profile"
    profile_marker = "# bash_config: source bashrc"
    profile_snippet = f"""
{profile_marker}
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
"""
    if bash_profile.exists():
        ensure_snippet(bash_profile, profile_marker, profile_snippet)

    print(f"Installed aliases and functions into {aliases_dir} and {functions_dir}")


if __name__ == "__main__":
    main()
