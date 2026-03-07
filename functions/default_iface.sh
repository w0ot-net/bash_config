: "${TMPDIR:=/tmp}"
_DEFAULT_IFACE_DIR="${TMPDIR%/}/default-iface-state"
_DEFAULT_IFACE_TABLE=42
_DEFAULT_IFACE_PRIO=100

mkdir -p "$_DEFAULT_IFACE_DIR"

_default_iface_rebuild() {
    local blocked line skip iface f

    blocked=$(
        for f in "$_DEFAULT_IFACE_DIR"/*.blocked; do
            [ -f "$f" ] || continue
            f=${f##*/}
            printf '%s\n' "${f%.blocked}"
        done
    )

    ip route flush table "$_DEFAULT_IFACE_TABLE" 2>/dev/null

    if [ -z "$blocked" ]; then
        ip rule del priority "$_DEFAULT_IFACE_PRIO" 2>/dev/null
        ip rule del priority 32766 2>/dev/null
        ip rule add priority 32766 lookup main
        return
    fi

    ip route show default | while IFS= read -r line; do
        skip=false
        for iface in $blocked; do
            case $line in
                *" dev $iface "*|*" dev $iface") skip=true; break ;;
            esac
        done
        $skip || ip route add $line table "$_DEFAULT_IFACE_TABLE"
    done

    ip rule del priority "$_DEFAULT_IFACE_PRIO" 2>/dev/null
    ip rule add priority "$_DEFAULT_IFACE_PRIO" lookup "$_DEFAULT_IFACE_TABLE"

    ip rule del priority 32766 2>/dev/null
    ip rule add priority 32766 lookup main suppress_prefixlength 0
}

default_iface_block() {
    local iface="$1"

    [ -n "$iface" ] || { printf 'usage: default_iface_block INTERFACE\n' >&2; return 2; }
    command -v ip >/dev/null 2>&1 || { printf 'default_iface_block: ip not found\n' >&2; return 1; }
    ip link show dev "$iface" >/dev/null 2>&1 || { printf 'default_iface_block: interface not found: %s\n' "$iface" >&2; return 1; }

    : > "$_DEFAULT_IFACE_DIR/$iface.blocked"
    _default_iface_rebuild
    printf 'blocked default routes for %s\n' "$iface"
}

default_iface_restore() {
    local iface="$1"

    [ -n "$iface" ] || { printf 'usage: default_iface_restore INTERFACE\n' >&2; return 2; }
    command -v ip >/dev/null 2>&1 || { printf 'default_iface_restore: ip not found\n' >&2; return 1; }
    [ -f "$_DEFAULT_IFACE_DIR/$iface.blocked" ] || { printf 'default_iface_restore: %s is not blocked\n' "$iface" >&2; return 1; }

    rm -f "$_DEFAULT_IFACE_DIR/$iface.blocked"
    _default_iface_rebuild
    printf 'restored default routes for %s\n' "$iface"
}

default_iface_prefer() {
    local preferred="$1"
    local line other

    [ -n "$preferred" ] || { printf 'usage: default_iface_prefer INTERFACE\n' >&2; return 2; }
    command -v ip >/dev/null 2>&1 || { printf 'default_iface_prefer: ip not found\n' >&2; return 1; }
    ip link show dev "$preferred" >/dev/null 2>&1 || { printf 'default_iface_prefer: interface not found: %s\n' "$preferred" >&2; return 1; }

    ip route show default | while IFS= read -r line; do
        case $line in
            *" dev $preferred "*|*" dev $preferred") ;;
            *" dev "*)
                other=${line#* dev }
                other=${other%% *}
                : > "$_DEFAULT_IFACE_DIR/$other.blocked"
                ;;
        esac
    done

    _default_iface_rebuild
    printf 'preferred %s; blocked all other default routes\n' "$preferred"
}
