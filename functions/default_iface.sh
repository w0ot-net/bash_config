: "${TMPDIR:=/tmp}"
_DEFAULT_IFACE_DIR="${TMPDIR%/}/default-iface-state"
_DEFAULT_IFACE_TABLE=42
_DEFAULT_IFACE_PRIO=100
_DEFAULT_IFACE_REPLY_PRIO=50

mkdir -p "$_DEFAULT_IFACE_DIR"

_default_iface_discover_gw() {
    local iface="$1" gw=""
    local lease_files=(
        /var/lib/dhcp/dhclient.leases
        "/var/lib/dhcp/dhclient.${iface}.leases"
        "/var/lib/dhcp/dhclient-${iface}.leases"
    )
    local nm_dir="/var/lib/NetworkManager"
    local f

    # Check NetworkManager internal lease files
    if [ -d "$nm_dir" ]; then
        for f in "$nm_dir"/*-"${iface}".lease "$nm_dir"/internal-*-"${iface}".lease; do
            [ -f "$f" ] && lease_files+=("$f")
        done
    fi

    for f in "${lease_files[@]}"; do
        [ -f "$f" ] || continue
        # Parse most recent lease block for this interface
        gw=$(awk -v iface="$iface" '
            /^lease \{/              { in_lease=1; cur_iface=""; cur_gw="" }
            in_lease && /interface/  { gsub(/[";]/, ""); cur_iface=$2 }
            in_lease && /option routers/ { gsub(/[;]/, ""); cur_gw=$3 }
            in_lease && /\}/         {
                if ((cur_iface == "" || cur_iface == iface) && cur_gw != "")
                    gw = cur_gw
                in_lease=0
            }
            END { print gw }
        ' "$f")
        [ -n "$gw" ] && { printf '%s' "$gw"; return 0; }
    done

    return 1
}

_default_iface_has_default_route() {
    ip route show default dev "$1" 2>/dev/null | grep -q .
}

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
    while ip rule del priority "$_DEFAULT_IFACE_REPLY_PRIO" 2>/dev/null; do :; done

    if [ -z "$blocked" ]; then
        ip rule del priority "$_DEFAULT_IFACE_PRIO" 2>/dev/null
        ip rule del priority 32766 2>/dev/null
        ip rule add priority 32766 lookup main
        return
    fi

    # Safety net: verify at least one default route will survive
    local have_route=false
    ip route show default | while IFS= read -r line; do
        skip=false
        for iface in $blocked; do
            case $line in
                *" dev $iface "*|*" dev $iface") skip=true; break ;;
            esac
        done
        $skip || { have_route=true; ip route add $line table "$_DEFAULT_IFACE_TABLE"; }
    done

    # Subshell pipe means have_route doesn't propagate; check the table directly
    if ! ip route show table "$_DEFAULT_IFACE_TABLE" 2>/dev/null | grep -q .; then
        printf 'default_iface: aborting — no default routes would remain\n' >&2
        printf 'default_iface: rolling back block state\n' >&2
        for f in "$_DEFAULT_IFACE_DIR"/*.blocked; do
            [ -f "$f" ] && rm -f "$f"
        done
        ip rule del priority "$_DEFAULT_IFACE_PRIO" 2>/dev/null
        ip rule del priority 32766 2>/dev/null
        ip rule add priority 32766 lookup main
        return 1
    fi

    ip rule del priority "$_DEFAULT_IFACE_PRIO" 2>/dev/null
    ip rule add priority "$_DEFAULT_IFACE_PRIO" lookup "$_DEFAULT_IFACE_TABLE"

    ip rule del priority 32766 2>/dev/null
    ip rule add priority 32766 lookup main suppress_prefixlength 0

    # Source-based rules: reply traffic from blocked interface IPs still routes normally
    local addr
    for iface in $blocked; do
        for addr in $(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}'); do
            ip rule add from "${addr%/*}" lookup main priority "$_DEFAULT_IFACE_REPLY_PRIO"
        done
    done
}

default_iface_block() {
    local iface="$1"

    [ -n "$iface" ] || { printf 'usage: default_iface_block INTERFACE\n' >&2; return 2; }
    command -v ip >/dev/null 2>&1 || { printf 'default_iface_block: ip not found\n' >&2; return 1; }
    ip link show dev "$iface" >/dev/null 2>&1 || { printf 'default_iface_block: interface not found: %s\n' "$iface" >&2; return 1; }

    : > "$_DEFAULT_IFACE_DIR/$iface.blocked"
    if ! _default_iface_rebuild; then
        printf 'default_iface_block: refused — blocking %s would leave no default routes\n' "$iface" >&2
        return 1
    fi
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
    local line other gw

    [ -n "$preferred" ] || { printf 'usage: default_iface_prefer INTERFACE\n' >&2; return 2; }
    command -v ip >/dev/null 2>&1 || { printf 'default_iface_prefer: ip not found\n' >&2; return 1; }
    ip link show dev "$preferred" >/dev/null 2>&1 || { printf 'default_iface_prefer: interface not found: %s\n' "$preferred" >&2; return 1; }

    # Ensure the preferred interface has a default route; auto-add from DHCP if missing
    if ! _default_iface_has_default_route "$preferred"; then
        gw=$(_default_iface_discover_gw "$preferred")
        if [ -n "$gw" ]; then
            # Use metric 10 to avoid "File exists" conflict with existing default routes
            if ip route add default via "$gw" dev "$preferred" metric 10 2>/dev/null; then
                printf 'default_iface_prefer: added default route via %s dev %s (from DHCP lease)\n' "$gw" "$preferred" >&2
            elif _default_iface_has_default_route "$preferred"; then
                printf 'default_iface_prefer: default route via %s dev %s already present\n' "$gw" "$preferred" >&2
            else
                printf 'default_iface_prefer: failed to add default route via %s dev %s\n' "$gw" "$preferred" >&2
                return 1
            fi
        else
            local subnet
            subnet=$(ip -4 -o addr show dev "$preferred" 2>/dev/null | awk '{print $4}' | head -1)
            printf 'default_iface_prefer: %s has no default route and no DHCP lease found\n' "$preferred" >&2
            if [ -n "$subnet" ]; then
                local net="${subnet%.*}"
                printf 'default_iface_prefer: try: ip route add default via %s.1 dev %s\n' "$net" "$preferred" >&2
                printf 'default_iface_prefer:   or: ip route add default via %s.2 dev %s\n' "$net" "$preferred" >&2
            fi
            return 1
        fi
    fi

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

    if ! _default_iface_rebuild; then
        return 1
    fi
    printf 'preferred %s; blocked all other default routes\n' "$preferred"
}

default_iface_status() {
    local f iface

    command -v ip >/dev/null 2>&1 || { printf 'default_iface_status: ip not found\n' >&2; return 1; }

    printf 'blocked interfaces:'
    local any=false
    for f in "$_DEFAULT_IFACE_DIR"/*.blocked; do
        [ -f "$f" ] || continue
        f=${f##*/}
        printf ' %s' "${f%.blocked}"
        any=true
    done
    $any || printf ' (none)'
    printf '\n'

    printf '\ndefault routes (main table):\n'
    ip route show default | sed 's/^/  /' || printf '  (none)\n'

    if ip rule show 2>/dev/null | grep -q "lookup $_DEFAULT_IFACE_TABLE"; then
        printf '\nactive routes (table %s):\n' "$_DEFAULT_IFACE_TABLE"
        ip route show table "$_DEFAULT_IFACE_TABLE" 2>/dev/null | sed 's/^/  /'
    fi

    printf '\negress test: '
    local egress_dev
    egress_dev=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    if [ -n "$egress_dev" ]; then
        printf '%s\n' "$egress_dev"
    else
        printf 'no route to internet\n'
    fi
}
