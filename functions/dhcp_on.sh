dhcp_on() {
    local iface="$1"

    [ -n "$iface" ] || { printf 'usage: dhcp_on INTERFACE\n' >&2; return 2; }
    command -v nmcli >/dev/null 2>&1 || { printf 'dhcp_on: nmcli not found\n' >&2; return 1; }

    local con
    con=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v dev="$iface" '$2 == dev {print $1; exit}')
    [ -n "$con" ] || { printf 'dhcp_on: no active connection on %s\n' "$iface" >&2; return 1; }

    nmcli con mod "$con" ipv4.method auto ipv4.addresses "" ipv4.gateway ""
    nmcli con up "$con" >/dev/null 2>&1

    printf 'dhcp enabled on %s (%s)\n' "$iface" "$con"
}
