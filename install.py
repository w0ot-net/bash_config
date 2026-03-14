#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path


def collect_managed_names(repo_dir: Path) -> set[str]:
    """Return stem names from aliases/*.sh and functions/*.sh."""
    names: set[str] = set()
    for sub in ("aliases", "functions"):
        d = repo_dir / sub
        if d.is_dir():
            for f in d.glob("*.sh"):
                names.add(f.stem)
    return names


def clean_bashrc(rc_file: Path, managed_names: set[str]) -> None:
    """Remove stale alias/function definitions and the v1 loader block."""
    if not rc_file.exists():
        return
    content = rc_file.read_text()
    lines = content.splitlines(keepends=True)

    result: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Remove alias lines for managed names
        m = re.match(r"^\s*alias\s+([\w][\w-]*)=", line)
        if m and m.group(1) in managed_names:
            i += 1
            continue

        # Remove inline function blocks for managed names (brace-depth)
        m = re.match(r"^([\w][\w-]*)\s*\(\)\s*\{", line)
        if m and m.group(1) in managed_names:
            depth = 0
            while i < len(lines):
                for ch in lines[i]:
                    if ch == "{":
                        depth += 1
                    elif ch == "}":
                        depth -= 1
                i += 1
                if depth <= 0:
                    break
            continue

        # Remove v1 loader block (# bash_config loader, without v2)
        if re.match(r"^#\s*bash_config\s+loader\s*$", stripped):
            fi_count = 0
            while i < len(lines):
                if lines[i].strip() == "fi":
                    fi_count += 1
                i += 1
                if fi_count >= 2:
                    break
            continue

        result.append(line)
        i += 1

    new_content = "".join(result)
    # Collapse runs of 3+ blank lines to 2
    new_content = re.sub(r"\n{4,}", "\n\n\n", new_content)

    if new_content != content:
        rc_file.write_text(new_content)


def link_dir(src_dir: Path, dst_dir: Path) -> None:
    if dst_dir.exists() and not dst_dir.is_dir():
        dst_dir.unlink()
    dst_dir.mkdir(parents=True, exist_ok=True)
    src_names = {f.name for f in src_dir.glob("*.sh")}
    for target in dst_dir.glob("*.sh"):
        if target.is_symlink() and target.name not in src_names:
            target.unlink()
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

    rc_file = Path.home() / ".bashrc"
    managed_names = collect_managed_names(repo_dir)
    clean_bashrc(rc_file, managed_names)

    bashrc_marker = "# bash_config loader v2"
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
    # Export functions so bash subshells (watch, xargs, bash -c) see them.
    for file in "$HOME/.bash_functions"/*.sh; do
        [ -e "$file" ] || continue
        export -f "$(basename "${{file%.sh}}")" 2>/dev/null
    done
fi
"""
    ensure_snippet(rc_file, bashrc_marker, bashrc_snippet)

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
