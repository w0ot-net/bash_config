#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

aliases_dir="$HOME/.bash_aliases"
functions_dir="$HOME/.bash_functions"

mkdir -p "$aliases_dir" "$functions_dir"

link_dir() {
    local src_dir="$1"
    local dst_dir="$2"
    local file

    for file in "$src_dir"/*.sh; do
        [ -e "$file" ] || continue
        ln -sf "$file" "$dst_dir/$(basename "$file")"
    done
}

link_dir "$repo_dir/aliases" "$aliases_dir"
link_dir "$repo_dir/functions" "$functions_dir"

ensure_loader() {
    local rc_file="$1"
    local marker="# bash_config loader"

    if [ ! -f "$rc_file" ]; then
        touch "$rc_file"
    fi

    if ! rg -q "$marker" "$rc_file"; then
        cat >> "$rc_file" <<'EOF'

# bash_config loader
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
EOF
    fi
}

ensure_loader "$HOME/.bashrc"

if [ -f "$HOME/.bash_profile" ] && ! rg -q "bashrc" "$HOME/.bash_profile"; then
    cat >> "$HOME/.bash_profile" <<'EOF'

if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
EOF
fi

echo "Installed aliases and functions into $aliases_dir and $functions_dir"
