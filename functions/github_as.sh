github_as() {
    (
        # Keep tokens out of xtrace without changing the caller's shell options.
        set +x

        if (($# < 2)) || [[ -z "${1:-}" || -z "${2:-}" ]]; then
            printf 'usage: github_as <username> <command> [arguments...]\n' >&2
            return 2
        fi

        local github_as_user="$1" github_as_token
        shift

        command -v gh >/dev/null 2>&1 || {
            printf 'github_as: gh not found\n' >&2
            return 1
        }

        if ! github_as_token=$(command gh auth token --hostname github.com --user "$github_as_user"); then
            printf 'github_as: cannot retrieve credentials for %s; log in with gh auth login --hostname github.com\n' \
                "$github_as_user" >&2
            return 1
        fi
        if [[ -z "$github_as_token" ]]; then
            printf 'github_as: no token for %s; log in with gh auth login --hostname github.com\n' \
                "$github_as_user" >&2
            return 1
        fi

        export GH_TOKEN="$github_as_token" || return 1
        "$@"
    )
}
