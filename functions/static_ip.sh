_STATIC_IP_STATE="/tmp/static-ip-state"
_STATIC_IP_HOOK="/etc/dhcp/dhclient-enter-hooks"
_STATIC_IP_MARKER="# --- set_static_ip guard ---"

mkdir -p "$_STATIC_IP_STATE"

# Install a guard into the dhclient-enter-hooks file (sourced by dhclient-script).
# When dhclient runs on a blocked interface, `exit 0` terminates the sourcing
# dhclient-script process, preventing any address/route changes.
_static_ip_install_hook() {
    [ -f "$_STATIC_IP_HOOK" ] && grep -qF "$_STATIC_IP_MARKER" "$_STATIC_IP_HOOK" && return 0
    cat >> "$_STATIC_IP_HOOK" <<'HOOK'

# --- set_static_ip guard ---
if [ -f "/tmp/static-ip-state/${interface}.static" ]; then
    exit 0
fi
# --- end set_static_ip guard ---
HOOK
}

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
    command dhclient -r "$iface" 2>/dev/null

    # Set static address
    ip addr flush dev "$iface"
    ip addr add "$addr" dev "$iface"
    ip link set dev "$iface" up

    # Restore default route
    [ -n "$gw" ] && ip route replace default via "$gw" dev "$iface"

    # Block future dhclient runs on this interface
    _static_ip_install_hook
    printf '%s\n' "$addr" > "$_STATIC_IP_STATE/$iface.static"

    printf 'set static %s on %s; dhclient blocked\n' "$addr" "$iface"
}

set_dynamic_ip() {
    local iface="$1"

    [ -n "$iface" ] || { printf 'usage: set_dynamic_ip INTERFACE\n' >&2; return 2; }
    command -v ip >/dev/null 2>&1 || { printf 'set_dynamic_ip: ip not found\n' >&2; return 1; }
    ip link show dev "$iface" >/dev/null 2>&1 || { printf 'set_dynamic_ip: interface not found: %s\n' "$iface" >&2; return 1; }

    # Remove state (unblocks dhclient via the hook's file check)
    rm -f "$_STATIC_IP_STATE/$iface.static"

    # Flush and acquire via DHCP
    ip addr flush dev "$iface"
    command dhclient "$iface"

    printf 'restored DHCP on %s\n' "$iface"
}
