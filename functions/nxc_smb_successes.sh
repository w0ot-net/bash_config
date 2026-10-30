nxc_smb_successes() {
    local workspace="${1:-}"
    local nxc_path="${NXC_PATH:-$HOME/.nxc}"
    local config="$nxc_path/nxc.conf"
    local database

    if (($# > 1)); then
        printf 'usage: nxc_smb_successes [workspace]\n' >&2
        return 2
    fi

    command -v sqlite3 >/dev/null 2>&1 || {
        printf 'nxc_smb_successes: sqlite3 not found\n' >&2
        return 1
    }

    if [[ -z "$workspace" ]]; then
        [[ -r "$config" ]] || {
            printf 'nxc_smb_successes: cannot read %s\n' "$config" >&2
            return 1
        }
        command -v awk >/dev/null 2>&1 || {
            printf 'nxc_smb_successes: awk not found\n' >&2
            return 1
        }
        workspace=$(command awk -F= '
            /^[[:space:]]*workspace[[:space:]]*=/ {
                value = $0
                sub(/^[^=]*=[[:space:]]*/, "", value)
                sub(/[[:space:]]*$/, "", value)
                print value
                exit
            }
        ' "$config")
        [[ -n "$workspace" ]] || {
            printf 'nxc_smb_successes: no active workspace found in %s\n' "$config" >&2
            return 1
        }
    fi

    database="$nxc_path/workspaces/$workspace/smb.db"
    [[ -r "$database" ]] || {
        printf 'nxc_smb_successes: cannot read %s\n' "$database" >&2
        return 1
    }

    command sqlite3 -readonly -header -box "$database" <<'SQL'
SELECT DISTINCT
    h.ip,
    h.hostname,
    h.os,
    u.domain,
    u.username,
    u.credtype AS credential_type,
    u.password AS credential,
    CASE WHEN ar.id IS NULL THEN 'no' ELSE 'yes' END AS admin
FROM loggedin_relations AS lr
JOIN hosts AS h ON h.id = lr.hostid
JOIN users AS u ON u.id = lr.userid
LEFT JOIN admin_relations AS ar
    ON ar.hostid = lr.hostid
   AND ar.userid = lr.userid
ORDER BY h.ip;
SQL
}
