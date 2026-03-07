dhcp_off() {
    local iface="$1"

    [ -n "$iface" ] || { printf 'usage: dhcp_off INTERFACE\n' >&2; return 2; }
    command -v nmcli >/dev/null 2>&1 || { printf 'dhcp_off: nmcli not found\n' >&2; return 1; }

    local con
    con=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v dev="$iface" '$2 == dev {print $1; exit}')
    [ -n "$con" ] || { printf 'dhcp_off: no active connection on %s\n' "$iface" >&2; return 1; }

    local addr
    addr=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')
    [ -n "$addr" ] || { printf 'dhcp_off: no IPv4 address on %s\n' "$iface" >&2; return 1; }

    local gw
    gw=$(ip -4 route show default dev "$iface" 2>/dev/null | awk '{print $3; exit}')

    nmcli con mod "$con" ipv4.method manual ipv4.addresses "$addr"
    [ -n "$gw" ] && nmcli con mod "$con" ipv4.gateway "$gw"
    nmcli con up "$con" >/dev/null 2>&1

    printf 'dhcp disabled on %s (%s)\n' "$iface" "$con"
}
