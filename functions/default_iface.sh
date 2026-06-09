# default_iface — make a single interface the system's default egress,
# fail-closed, using NetworkManager as the source of truth.
#
# Preference is expressed entirely through NM connection properties:
#   preferred iface : ipv4.never-default no  + low ipv4.route-metric
#                     + exclusive DNS (negative ipv4.dns-priority)
#   every other     : ipv4.never-default yes + ipv4.ignore-auto-dns yes
#
# Because the policy lives in the connection profiles, NM re-applies it
# automatically on carrier-up, DHCP renewal, gateway change, and reboot —
# no custom routing table, no ip rules, no dispatcher hook, no /tmp state.
# When the preferred iface is down there is simply no default route, so
# traffic fails closed instead of leaking onto another network.

_DEFAULT_IFACE_STATE_DIR="/var/lib/default-iface"
_DEFAULT_IFACE_PREF_METRIC=50
_DEFAULT_IFACE_DNS_PRIO=-50

_default_iface_have_nmcli() {
    command -v nmcli >/dev/null 2>&1 || {
        printf 'default_iface: nmcli not found (NetworkManager required)\n' >&2
        return 1
    }
}

# Resolve an interface name to the UUID of the connection that governs it:
# the active connection if there is one, otherwise a saved profile bound to it.
_default_iface_con_for_iface() {
    local iface="$1" name uuid ifn
    name=$(nmcli -t -g GENERAL.CONNECTION device show "$iface" 2>/dev/null)
    if [ -n "$name" ] && [ "$name" != "--" ]; then
        uuid=$(nmcli -g connection.uuid connection show "$name" 2>/dev/null)
        [ -n "$uuid" ] && { printf '%s' "$uuid"; return 0; }
    fi
    while IFS= read -r uuid; do
        [ -n "$uuid" ] || continue
        ifn=$(nmcli -g connection.interface-name connection show "$uuid" 2>/dev/null)
        [ "$ifn" = "$iface" ] && { printf '%s' "$uuid"; return 0; }
    done < <(nmcli -t -g UUID connection show 2>/dev/null)
    return 1
}

# UUIDs of all active connections that can carry a default route.
_default_iface_default_capable_cons() {
    local name uuid type dev
    while IFS=: read -r name uuid type dev; do
        case "$type" in
            802-3-ethernet|802-11-wireless) printf '%s\n' "$uuid" ;;
        esac
    done < <(nmcli -t -f NAME,UUID,TYPE,DEVICE connection show --active 2>/dev/null)
}

_default_iface_dev_of() {
    nmcli -g GENERAL.DEVICES connection show "$1" 2>/dev/null | head -1
}

# Re-apply a connection's settings to its device with minimal disruption.
_default_iface_apply() {
    local uuid="$1" dev
    dev=$(_default_iface_dev_of "$uuid")
    if [ -n "$dev" ] && nmcli device reapply "$dev" >/dev/null 2>&1; then
        return 0
    fi
    nmcli connection up "$uuid" >/dev/null 2>&1
}

# Snapshot a connection's original ipv4 routing/DNS props once, so restore
# can put them back exactly. Never overwrites an existing snapshot.
_default_iface_save_orig() {
    local uuid="$1" f="$_DEFAULT_IFACE_STATE_DIR/$uuid.orig"
    [ -f "$f" ] && return 0
    mkdir -p "$_DEFAULT_IFACE_STATE_DIR"
    {
        printf 'route-metric=%s\n'    "$(nmcli -g ipv4.route-metric    connection show "$uuid" 2>/dev/null)"
        printf 'never-default=%s\n'   "$(nmcli -g ipv4.never-default   connection show "$uuid" 2>/dev/null)"
        printf 'dns-priority=%s\n'    "$(nmcli -g ipv4.dns-priority    connection show "$uuid" 2>/dev/null)"
        printf 'ignore-auto-dns=%s\n' "$(nmcli -g ipv4.ignore-auto-dns connection show "$uuid" 2>/dev/null)"
    } > "$f"
}

_default_iface_restore_con() {
    local uuid="$1" f="$_DEFAULT_IFACE_STATE_DIR/$uuid.orig"
    local k v rm nd dp iad
    [ -f "$f" ] || { printf 'default_iface: no saved state for %s\n' "$uuid" >&2; return 1; }
    while IFS='=' read -r k v; do
        case "$k" in
            route-metric)    rm="$v" ;;
            never-default)   nd="$v" ;;
            dns-priority)    dp="$v" ;;
            ignore-auto-dns) iad="$v" ;;
        esac
    done < "$f"
    nmcli connection modify "$uuid" \
        ipv4.route-metric    "${rm:--1}" \
        ipv4.never-default   "${nd:-no}" \
        ipv4.dns-priority    "${dp:-0}" \
        ipv4.ignore-auto-dns "${iad:-no}" 2>/dev/null
    _default_iface_apply "$uuid"
    rm -f "$f"
}

# Tear down the previous policy-routing implementation (custom table 42,
# ip rules, /tmp state, dispatcher hook) if it is still present. Idempotent.
_default_iface_teardown_legacy() {
    local removed=0 r old="/tmp/default-iface-state"

    if ip rule show 2>/dev/null | grep -q "lookup 42"; then
        ip route flush table 42 2>/dev/null
        while ip rule del priority 100 2>/dev/null; do :; done
        while ip rule del priority 50  2>/dev/null; do :; done
        if ip rule show 2>/dev/null | grep -q "32766:.*suppress_prefixlength"; then
            ip rule del priority 32766 2>/dev/null
            ip rule add priority 32766 lookup main 2>/dev/null
        fi
        removed=1
    fi

    # Drop any default route the old prefer added by hand (it used metric 10).
    while IFS= read -r r; do
        [ -n "$r" ] && ip route del $r 2>/dev/null
    done < <(ip route show default 2>/dev/null | grep 'metric 10')

    if [ -d "$old" ]; then
        [ -f "$old/resolv.conf.bak" ] && cp "$old/resolv.conf.bak" /etc/resolv.conf 2>/dev/null
        rm -rf "$old"
        removed=1
    fi

    if [ -f /etc/NetworkManager/dispatcher.d/90-default-iface ]; then
        rm -f /etc/NetworkManager/dispatcher.d/90-default-iface
        rm -f /tmp/default-iface-dispatcher.log
        removed=1
    fi

    [ "$removed" = 1 ] && \
        printf 'default_iface: migrated off legacy policy-routing/dispatcher setup\n' >&2
    return 0
}

default_iface_prefer() {
    local preferred="$1" pref_uuid uuid subnet net

    [ -n "$preferred" ] || { printf 'usage: default_iface_prefer INTERFACE\n' >&2; return 2; }
    _default_iface_have_nmcli || return 1
    ip link show dev "$preferred" >/dev/null 2>&1 || {
        printf 'default_iface_prefer: interface not found: %s\n' "$preferred" >&2; return 1; }

    pref_uuid=$(_default_iface_con_for_iface "$preferred")
    if [ -z "$pref_uuid" ]; then
        printf 'default_iface_prefer: no NetworkManager connection for %s\n' "$preferred" >&2
        printf 'default_iface_prefer: create one with:\n' >&2
        printf '  nmcli connection add type ethernet con-name %s ifname %s ipv4.method auto connection.autoconnect yes\n' \
            "$preferred" "$preferred" >&2
        return 1
    fi

    _default_iface_teardown_legacy
    mkdir -p "$_DEFAULT_IFACE_STATE_DIR"

    # Preferred connection: owns the default route, exclusive DNS.
    _default_iface_save_orig "$pref_uuid"
    nmcli connection modify "$pref_uuid" \
        ipv4.never-default no \
        ipv4.route-metric "$_DEFAULT_IFACE_PREF_METRIC" \
        ipv4.ignore-auto-dns no \
        ipv4.dns-priority "$_DEFAULT_IFACE_DNS_PRIO" \
        connection.autoconnect yes 2>/dev/null || {
            printf 'default_iface_prefer: failed to configure %s\n' "$preferred" >&2; return 1; }
    printf '%s' "$pref_uuid" > "$_DEFAULT_IFACE_STATE_DIR/preferred"

    # Every other default-capable connection: fail closed.
    while IFS= read -r uuid; do
        [ -n "$uuid" ] || continue
        [ "$uuid" = "$pref_uuid" ] && continue
        _default_iface_save_orig "$uuid"
        nmcli connection modify "$uuid" \
            ipv4.never-default yes \
            ipv4.ignore-auto-dns yes 2>/dev/null
    done < <(_default_iface_default_capable_cons)

    # Apply others first, then the preferred so its route/DNS settle last.
    while IFS= read -r uuid; do
        [ -n "$uuid" ] || continue
        [ "$uuid" = "$pref_uuid" ] && continue
        _default_iface_apply "$uuid"
    done < <(_default_iface_default_capable_cons)
    _default_iface_apply "$pref_uuid"

    printf 'preferred %s; all other interfaces fail closed (never-default)\n' "$preferred"
}

default_iface_block() {
    local iface="$1" uuid

    [ -n "$iface" ] || { printf 'usage: default_iface_block INTERFACE\n' >&2; return 2; }
    _default_iface_have_nmcli || return 1
    ip link show dev "$iface" >/dev/null 2>&1 || {
        printf 'default_iface_block: interface not found: %s\n' "$iface" >&2; return 1; }

    uuid=$(_default_iface_con_for_iface "$iface")
    [ -n "$uuid" ] || { printf 'default_iface_block: no NetworkManager connection for %s\n' "$iface" >&2; return 1; }

    _default_iface_save_orig "$uuid"
    nmcli connection modify "$uuid" \
        ipv4.never-default yes \
        ipv4.ignore-auto-dns yes 2>/dev/null || {
            printf 'default_iface_block: failed to modify %s\n' "$iface" >&2; return 1; }
    _default_iface_apply "$uuid"
    printf 'blocked default routes for %s\n' "$iface"
}

default_iface_restore() {
    local iface="$1" uuid f

    _default_iface_have_nmcli || return 1

    if [ -n "$iface" ]; then
        uuid=$(_default_iface_con_for_iface "$iface")
        [ -n "$uuid" ] || { printf 'default_iface_restore: no NetworkManager connection for %s\n' "$iface" >&2; return 1; }
        _default_iface_restore_con "$uuid" || return 1
        printf 'restored default routes for %s\n' "$iface"
        return 0
    fi

    # No argument: revert every connection default_iface has touched.
    local any=false
    for f in "$_DEFAULT_IFACE_STATE_DIR"/*.orig; do
        [ -f "$f" ] || continue
        uuid=${f##*/}; uuid=${uuid%.orig}
        _default_iface_restore_con "$uuid"
        any=true
    done
    rm -f "$_DEFAULT_IFACE_STATE_DIR/preferred"
    $any && printf 'restored all interfaces modified by default_iface\n' \
         || printf 'default_iface_restore: nothing to restore\n'
}

default_iface_status() {
    local name uuid type dev m nd dp egress

    _default_iface_have_nmcli || return 1

    printf 'preferred: '
    if [ -f "$_DEFAULT_IFACE_STATE_DIR/preferred" ]; then
        local puuid; puuid=$(cat "$_DEFAULT_IFACE_STATE_DIR/preferred")
        nmcli -g connection.interface-name connection show "$puuid" 2>/dev/null || printf '%s\n' "$puuid"
    else
        printf '(none)\n'
    fi

    printf '\n%-22s %-7s %-8s %-13s %-9s\n' CONNECTION DEVICE METRIC NEVER-DEFAULT DNS-PRIO
    while IFS=: read -r name uuid type dev; do
        case "$type" in 802-3-ethernet|802-11-wireless) ;; *) continue ;; esac
        m=$(nmcli  -g ipv4.route-metric  connection show "$uuid" 2>/dev/null)
        nd=$(nmcli -g ipv4.never-default connection show "$uuid" 2>/dev/null)
        dp=$(nmcli -g ipv4.dns-priority  connection show "$uuid" 2>/dev/null)
        printf '%-22s %-7s %-8s %-13s %-9s\n' "$name" "${dev:--}" "${m:--}" "${nd:--}" "${dp:--}"
    done < <(nmcli -t -f NAME,UUID,TYPE,DEVICE connection show --active 2>/dev/null)

    printf '\ndefault routes:\n'
    ip route show default 2>/dev/null | sed 's/^/  /'
    [ -n "$(ip route show default 2>/dev/null)" ] || printf '  (none — failing closed)\n'

    printf '\negress -> 8.8.8.8: '
    egress=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    [ -n "$egress" ] && printf '%s\n' "$egress" || printf 'no route (failing closed)\n'

    if ip rule show 2>/dev/null | grep -q "lookup 42" \
       || [ -f /etc/NetworkManager/dispatcher.d/90-default-iface ]; then
        printf '\nWARNING: legacy policy-routing/dispatcher artifacts present;\n'
        printf '         run default_iface_prefer to migrate them away.\n'
    fi
}
