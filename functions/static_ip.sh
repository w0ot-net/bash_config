: "${TMPDIR:=/tmp}"
_STATIC_IP_DIR="${TMPDIR%/}/static-ip-state"
_STATIC_IP_HOOKS_DIR="/etc/dhcp/dhclient-enter-hooks.d"

mkdir -p "$_STATIC_IP_DIR"

set_static_ip() {
    local iface="$1" addr="$2" gw="$3"

    [ -n "$iface" ] && [ -n "$addr" ] || {
        printf 'usage: set_static_ip INTERFACE ADDRESS[/PREFIX] [GATEWAY]\n' >&2
        return 2
    }
    command -v ip >/dev/null 2>&1 || { printf 'set_static_ip: ip not found\n' >&2; return 1; }
    ip link show dev "$iface" >/dev/null 2>&1 || { printf 'set_static_ip: interface not found: %s\n' "$iface" >&2; return 1; }

    case $addr in
        */*) ;;
        *)   addr="$addr/24" ;;
    esac

    # Capture current gateway before flushing
    if [ -z "$gw" ]; then
        gw=$(ip route show default dev "$iface" 2>/dev/null | awk '/via/{print $3; exit}')
    fi

    # Release DHCP lease and stop dhclient
    dhclient -r "$iface" 2>/dev/null

    # Set static address
    ip addr flush dev "$iface"
    ip addr add "$addr" dev "$iface"
    ip link set dev "$iface" up

    # Restore default route
    [ -n "$gw" ] && ip route replace default via "$gw" dev "$iface"

    # Block future dhclient runs on this interface
    mkdir -p "$_STATIC_IP_HOOKS_DIR" 2>/dev/null
    cat > "$_STATIC_IP_HOOKS_DIR/static-$iface" <<HOOK
# Installed by set_static_ip — block dhclient on $iface
if [ "\$interface" = "$iface" ]; then
    exit_status=1
fi
HOOK

    printf '%s\n' "$addr" > "$_STATIC_IP_DIR/$iface.static"
    printf 'set static %s on %s; dhclient blocked\n' "$addr" "$iface"
}

set_dynamic_ip() {
    local iface="$1"

    [ -n "$iface" ] || { printf 'usage: set_dynamic_ip INTERFACE\n' >&2; return 2; }
    command -v ip >/dev/null 2>&1 || { printf 'set_dynamic_ip: ip not found\n' >&2; return 1; }
    ip link show dev "$iface" >/dev/null 2>&1 || { printf 'set_dynamic_ip: interface not found: %s\n' "$iface" >&2; return 1; }

    # Remove dhclient block
    rm -f "$_STATIC_IP_HOOKS_DIR/static-$iface"
    rm -f "$_STATIC_IP_DIR/$iface.static"

    # Flush and acquire via DHCP
    ip addr flush dev "$iface"
    dhclient "$iface"

    printf 'restored DHCP on %s\n' "$iface"
}
