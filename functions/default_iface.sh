# default_iface — choose the system's default-egress interface, fail-closed,
# in a mixed environment where some interfaces are managed by NetworkManager
# and others (ipv4.method=disabled) get their address/route from manual
# dhclient.
#
# Principles:
#  * Management-aware: NetworkManager is used ONLY for interfaces whose IPv4
#    it actually manages (method auto|manual). For an interface NM does not
#    manage we operate purely at the routing layer and NEVER call nmcli on it
#    — running nmcli against a method=disabled iface makes NM reassert "no
#    IPv4" and wipes the manual address/route, knocking the box offline.
#  * Fail-safe: the preferred interface's default route is installed and
#    verified BEFORE any other interface's default is removed, so a failure
#    never leaves the system without egress. DNS is pointed at a nameserver
#    reachable via the preferred interface (original backed up for restore).
#  * Fail-closed: once the preferred route is confirmed, every other
#    interface's default route is removed so traffic cannot leak out them.

# Resolve real executables once, bypassing aliases/functions in the sourcing
# shell (alias expansion is baked in at definition time, so a trash-style
# `rm` or `grep --color` alias would otherwise corrupt these commands).
_DI_NMCLI="$(type -P nmcli       || echo /usr/bin/nmcli)"
_DI_IP="$(type -P ip             || echo /usr/sbin/ip)"
_DI_DHCLIENT="$(type -P dhclient || echo /usr/sbin/dhclient)"
_DI_PING="$(type -P ping         || echo /usr/bin/ping)"
_DI_RM="$(type -P rm             || echo /usr/bin/rm)"
_DI_CP="$(type -P cp             || echo /usr/bin/cp)"
_DI_CAT="$(type -P cat           || echo /usr/bin/cat)"
_DI_HEAD="$(type -P head         || echo /usr/bin/head)"
_DI_MKDIR="$(type -P mkdir       || echo /usr/bin/mkdir)"
_DI_GREP="$(type -P grep         || echo /usr/bin/grep)"
_DI_SED="$(type -P sed           || echo /usr/bin/sed)"
_DI_AWK="$(type -P awk           || echo /usr/bin/awk)"
_DI_SORT="$(type -P sort         || echo /usr/bin/sort)"

_DEFAULT_IFACE_STATE_DIR="/var/lib/default-iface"
_DEFAULT_IFACE_METRIC=50

_default_iface_have_ip() {
    [ -x "$_DI_IP" ] || { printf 'default_iface: ip not found\n' >&2; return 1; }
}

# UUID of the NM connection governing IFACE (active, else a profile bound to it).
_default_iface_con_for_iface() {
    local iface="$1" name uuid ifn
    [ -x "$_DI_NMCLI" ] || return 1
    name=$("$_DI_NMCLI" -t -g GENERAL.CONNECTION device show "$iface" 2>/dev/null)
    if [ -n "$name" ] && [ "$name" != "--" ]; then
        uuid=$("$_DI_NMCLI" -g connection.uuid connection show "$name" 2>/dev/null)
        [ -n "$uuid" ] && { printf '%s' "$uuid"; return 0; }
    fi
    while IFS= read -r uuid; do
        [ -n "$uuid" ] || continue
        ifn=$("$_DI_NMCLI" -g connection.interface-name connection show "$uuid" 2>/dev/null)
        [ "$ifn" = "$iface" ] && { printf '%s' "$uuid"; return 0; }
    done < <("$_DI_NMCLI" -t -g UUID connection show 2>/dev/null)
    return 1
}

# Does NetworkManager actually manage IPv4 on IFACE? (device managed AND
# ipv4.method is auto|manual). disabled/link-local/shared -> no.
_default_iface_nm_manages_ipv4() {
    local iface="$1" state uuid method
    [ -x "$_DI_NMCLI" ] || return 1
    state=$("$_DI_NMCLI" -t -f GENERAL.STATE device show "$iface" 2>/dev/null | "$_DI_HEAD" -1)
    case "$state" in *unmanaged*) return 1 ;; esac
    uuid=$(_default_iface_con_for_iface "$iface") || return 1
    method=$("$_DI_NMCLI" -g ipv4.method connection show "$uuid" 2>/dev/null)
    case "$method" in auto|manual) return 0 ;; *) return 1 ;; esac
}

_default_iface_cur_gw() {
    "$_DI_IP" -4 route show default dev "$1" 2>/dev/null \
        | "$_DI_AWK" '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
}

_default_iface_lease_files() {
    local iface="$1" nm_dir="/var/lib/NetworkManager" f
    printf '%s\n' /var/lib/dhcp/dhclient.leases
    printf '%s\n' "/var/lib/dhcp/dhclient.${iface}.leases"
    printf '%s\n' "/var/lib/dhcp/dhclient-${iface}.leases"
    if [ -d "$nm_dir" ]; then
        for f in "$nm_dir"/*-"${iface}".lease "$nm_dir"/internal-*-"${iface}".lease; do
            [ -f "$f" ] && printf '%s\n' "$f"
        done
    fi
}

# Parse the most recent value of a dhclient-lease option for IFACE.
# $2 = lease keyword (e.g. "option routers"), printed field is the last token.
_default_iface_lease_value() {
    local iface="$1" key="$2" val="" f
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        val=$("$_DI_AWK" -v iface="$iface" -v key="$key" '
            /^lease \{/             { in_lease=1; cur_iface=""; cur=""  }
            in_lease && /interface/ { gsub(/[";]/, ""); cur_iface=$2 }
            in_lease && index($0, key) { gsub(/[;]/, ""); cur=$NF }
            in_lease && /\}/        { if ((cur_iface==""||cur_iface==iface)&&cur!="") v=cur; in_lease=0 }
            END { print v }' "$f")
        [ -n "$val" ] && { printf '%s' "$val"; return 0; }
    done < <(_default_iface_lease_files "$iface")
    return 1
}

# Best gateway for IFACE: live default route, else NM, else dhclient lease.
_default_iface_gw_for() {
    local iface="$1" gw
    gw=$(_default_iface_cur_gw "$iface"); [ -n "$gw" ] && { printf '%s' "$gw"; return 0; }
    if _default_iface_nm_manages_ipv4 "$iface"; then
        gw=$("$_DI_NMCLI" -g IP4.GATEWAY device show "$iface" 2>/dev/null | "$_DI_HEAD" -1)
        [ -n "$gw" ] && { printf '%s' "$gw"; return 0; }
    fi
    _default_iface_lease_value "$iface" "option routers"
}

# Best DNS server for IFACE: NM (if managed), else dhclient lease.
_default_iface_dns_for() {
    local iface="$1" dns
    if _default_iface_nm_manages_ipv4 "$iface"; then
        dns=$("$_DI_NMCLI" -g IP4.DNS device show "$iface" 2>/dev/null | "$_DI_HEAD" -1)
        [ -n "$dns" ] && { printf '%s' "$dns"; return 0; }
    fi
    _default_iface_lease_value "$iface" "domain-name-servers"
}

# Interface that egress to the internet currently uses ("" if none).
_default_iface_egress_dev() {
    "$_DI_IP" route get 8.8.8.8 2>/dev/null \
        | "$_DI_AWK" '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# All non-loopback interfaces that have, or could install, a default route.
_default_iface_candidate_ifaces() {
    {
        "$_DI_IP" route show default 2>/dev/null \
            | "$_DI_AWK" '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'
        "$_DI_NMCLI" -t -f DEVICE,TYPE device status 2>/dev/null \
            | "$_DI_AWK" -F: '$2=="ethernet"||$2=="wifi"{print $1}'
    } | "$_DI_GREP" -vx 'lo' | "$_DI_SORT" -u
}

_default_iface_set_dns() {
    local dns="$1"
    [ -n "$dns" ] || return 0
    "$_DI_MKDIR" -p "$_DEFAULT_IFACE_STATE_DIR"
    [ -f "$_DEFAULT_IFACE_STATE_DIR/resolv.conf.bak" ] \
        || "$_DI_CP" /etc/resolv.conf "$_DEFAULT_IFACE_STATE_DIR/resolv.conf.bak" 2>/dev/null
    printf 'nameserver %s\n' "$dns" > /etc/resolv.conf
}

_default_iface_restore_dns() {
    if [ -f "$_DEFAULT_IFACE_STATE_DIR/resolv.conf.bak" ]; then
        "$_DI_CP" "$_DEFAULT_IFACE_STATE_DIR/resolv.conf.bak" /etc/resolv.conf 2>/dev/null
        "$_DI_RM" -f "$_DEFAULT_IFACE_STATE_DIR/resolv.conf.bak"
    fi
}

# Snapshot an NM connection's ipv4 props once, for exact restore.
_default_iface_save_orig() {
    local uuid="$1" f
    [ -n "$uuid" ] || return 1
    f="$_DEFAULT_IFACE_STATE_DIR/$uuid.orig"
    [ -f "$f" ] && return 0
    "$_DI_MKDIR" -p "$_DEFAULT_IFACE_STATE_DIR"
    {
        printf 'route-metric=%s\n'    "$("$_DI_NMCLI" -g ipv4.route-metric    connection show "$uuid" 2>/dev/null)"
        printf 'never-default=%s\n'   "$("$_DI_NMCLI" -g ipv4.never-default   connection show "$uuid" 2>/dev/null)"
        printf 'dns-priority=%s\n'    "$("$_DI_NMCLI" -g ipv4.dns-priority    connection show "$uuid" 2>/dev/null)"
        printf 'ignore-auto-dns=%s\n' "$("$_DI_NMCLI" -g ipv4.ignore-auto-dns connection show "$uuid" 2>/dev/null)"
    } > "$f"
}

_default_iface_restore_con() {
    local uuid="$1" f k v rm nd dp iad method
    f="$_DEFAULT_IFACE_STATE_DIR/$uuid.orig"
    [ -f "$f" ] || return 1
    # Only ever reactivate connections whose IPv4 NM actually manages. A
    # snapshot for a disabled/unmanaged connection is stale pollution from an
    # older version — applying `nmcli up` to it would strip a manual address.
    method=$("$_DI_NMCLI" -g ipv4.method connection show "$uuid" 2>/dev/null)
    case "$method" in
        auto|manual) ;;
        *) "$_DI_RM" -f "$f"; return 0 ;;
    esac
    while IFS='=' read -r k v; do
        case "$k" in
            route-metric)    rm="$v" ;;
            never-default)   nd="$v" ;;
            dns-priority)    dp="$v" ;;
            ignore-auto-dns) iad="$v" ;;
        esac
    done < "$f"
    "$_DI_NMCLI" connection modify "$uuid" \
        ipv4.route-metric    "${rm:--1}" \
        ipv4.never-default   "${nd:-no}" \
        ipv4.dns-priority    "${dp:-0}" \
        ipv4.ignore-auto-dns "${iad:-no}" 2>/dev/null
    "$_DI_NMCLI" connection up "$uuid" >/dev/null 2>&1
    "$_DI_RM" -f "$f"
}

# Remove a stale default route via IFACE, recording its gateway so restore
# can re-add it (manually-managed interfaces only).
_default_iface_block_manual() {
    local iface="$1" gw
    gw=$(_default_iface_cur_gw "$iface")
    [ -n "$gw" ] && printf '%s' "$gw" > "$_DEFAULT_IFACE_STATE_DIR/$iface.manualblock"
    while "$_DI_IP" route del default dev "$iface" 2>/dev/null; do :; done
}

# Tear down the previous policy-routing implementation if still present.
_default_iface_teardown_legacy() {
    local removed=0 r old="/tmp/default-iface-state"
    if "$_DI_IP" rule show 2>/dev/null | "$_DI_GREP" -q "lookup 42"; then
        "$_DI_IP" route flush table 42 2>/dev/null
        while "$_DI_IP" rule del priority 100 2>/dev/null; do :; done
        while "$_DI_IP" rule del priority 50  2>/dev/null; do :; done
        if "$_DI_IP" rule show 2>/dev/null | "$_DI_GREP" -q "32766:.*suppress_prefixlength"; then
            "$_DI_IP" rule del priority 32766 2>/dev/null
            "$_DI_IP" rule add priority 32766 lookup main 2>/dev/null
        fi
        removed=1
    fi
    while IFS= read -r r; do
        [ -n "$r" ] && "$_DI_IP" route del $r 2>/dev/null
    done < <("$_DI_IP" route show default 2>/dev/null | "$_DI_GREP" 'metric 10')
    if [ -d "$old" ]; then
        [ -f "$old/resolv.conf.bak" ] && "$_DI_CP" "$old/resolv.conf.bak" /etc/resolv.conf 2>/dev/null
        "$_DI_RM" -rf "$old"; removed=1
    fi
    if [ -f /etc/NetworkManager/dispatcher.d/90-default-iface ]; then
        "$_DI_RM" -f /etc/NetworkManager/dispatcher.d/90-default-iface
        "$_DI_RM" -f /tmp/default-iface-dispatcher.log; removed=1
    fi
    [ "$removed" = 1 ] && printf 'default_iface: migrated off legacy policy-routing setup\n' >&2
    return 0
}

default_iface_prefer() {
    local preferred="$1" pref_uuid gw dns egress other oth_uuid

    [ -n "$preferred" ] || { printf 'usage: default_iface_prefer INTERFACE\n' >&2; return 2; }
    _default_iface_have_ip || return 1
    "$_DI_IP" link show dev "$preferred" >/dev/null 2>&1 || {
        printf 'default_iface_prefer: interface not found: %s\n' "$preferred" >&2; return 1; }

    _default_iface_teardown_legacy
    "$_DI_MKDIR" -p "$_DEFAULT_IFACE_STATE_DIR"

    # 1. Install the preferred default route — WITHOUT removing any others yet.
    if _default_iface_nm_manages_ipv4 "$preferred"; then
        pref_uuid=$(_default_iface_con_for_iface "$preferred")
        _default_iface_save_orig "$pref_uuid"
        "$_DI_NMCLI" connection modify "$pref_uuid" \
            ipv4.never-default no \
            ipv4.route-metric "$_DEFAULT_IFACE_METRIC" \
            ipv4.ignore-auto-dns no \
            ipv4.dns-priority -50 \
            connection.autoconnect yes 2>/dev/null
        "$_DI_NMCLI" connection up "$pref_uuid" >/dev/null 2>&1
    elif [ -z "$(_default_iface_cur_gw "$preferred")" ]; then
        # Manual iface with no default route: establish one (don't stack a
        # duplicate when dhclient already installed a default).
        gw=$(_default_iface_gw_for "$preferred")
        if [ -z "$gw" ]; then
            printf 'default_iface_prefer: %s has no gateway; running dhclient...\n' "$preferred" >&2
            "$_DI_DHCLIENT" -4 "$preferred" >/dev/null 2>&1
            gw=$(_default_iface_gw_for "$preferred")
        fi
        [ -n "$gw" ] && "$_DI_IP" route replace default via "$gw" dev "$preferred" \
            metric "$_DEFAULT_IFACE_METRIC" 2>/dev/null
    fi

    # 2. SAFETY GATE: a default route via the preferred iface must now exist,
    #    or we abort without touching the working configuration.
    if [ -z "$(_default_iface_cur_gw "$preferred")" ]; then
        printf 'default_iface_prefer: ABORT — could not establish a default route via %s\n' "$preferred" >&2
        printf 'default_iface_prefer: existing routing left untouched; system still online\n' >&2
        return 1
    fi

    # 3. Confirmed reachable — fail-close every other default-capable iface.
    while IFS= read -r other; do
        [ -n "$other" ] || continue
        [ "$other" = "$preferred" ] && continue
        if _default_iface_nm_manages_ipv4 "$other"; then
            oth_uuid=$(_default_iface_con_for_iface "$other")
            _default_iface_save_orig "$oth_uuid"
            "$_DI_NMCLI" connection modify "$oth_uuid" \
                ipv4.never-default yes ipv4.ignore-auto-dns yes 2>/dev/null
            "$_DI_NMCLI" connection up "$oth_uuid" >/dev/null 2>&1
        else
            _default_iface_block_manual "$other"
            printf 'default_iface_prefer: note: %s is dhclient-managed; its default route was removed (a DHCP renewal may re-add it)\n' "$other" >&2
        fi
    done < <(_default_iface_candidate_ifaces)

    # 4. Point DNS at a server reachable via the preferred iface (set last so
    #    nmcli reactivations above cannot clobber it).
    dns=$(_default_iface_dns_for "$preferred")
    _default_iface_set_dns "$dns"

    # 5. Final check; if egress somehow isn't via the preferred iface, re-assert
    #    its default route rather than leave things wrong.
    egress=$(_default_iface_egress_dev)
    if [ "$egress" != "$preferred" ]; then
        gw=$(_default_iface_gw_for "$preferred")
        [ -n "$gw" ] && "$_DI_IP" route replace default via "$gw" dev "$preferred" \
            metric "$_DEFAULT_IFACE_METRIC" 2>/dev/null
        egress=$(_default_iface_egress_dev)
    fi

    printf '%s' "$preferred" > "$_DEFAULT_IFACE_STATE_DIR/preferred"
    printf 'preferred %s; egress now via %s; other interfaces fail-closed\n' \
        "$preferred" "${egress:-none}"
}

default_iface_block() {
    local iface="$1" uuid

    [ -n "$iface" ] || { printf 'usage: default_iface_block INTERFACE\n' >&2; return 2; }
    _default_iface_have_ip || return 1
    "$_DI_IP" link show dev "$iface" >/dev/null 2>&1 || {
        printf 'default_iface_block: interface not found: %s\n' "$iface" >&2; return 1; }
    "$_DI_MKDIR" -p "$_DEFAULT_IFACE_STATE_DIR"

    if _default_iface_nm_manages_ipv4 "$iface"; then
        uuid=$(_default_iface_con_for_iface "$iface")
        _default_iface_save_orig "$uuid"
        "$_DI_NMCLI" connection modify "$uuid" \
            ipv4.never-default yes ipv4.ignore-auto-dns yes 2>/dev/null
        "$_DI_NMCLI" connection up "$uuid" >/dev/null 2>&1
    else
        _default_iface_block_manual "$iface"
    fi
    printf 'blocked default routes for %s\n' "$iface"
}

default_iface_restore() {
    local iface="$1" uuid f gw ifn

    _default_iface_have_ip || return 1

    if [ -n "$iface" ]; then
        if _default_iface_nm_manages_ipv4 "$iface"; then
            uuid=$(_default_iface_con_for_iface "$iface")
            _default_iface_restore_con "$uuid"
        fi
        f="$_DEFAULT_IFACE_STATE_DIR/$iface.manualblock"
        if [ -f "$f" ]; then
            gw=$("$_DI_CAT" "$f")
            [ -n "$gw" ] && "$_DI_IP" route replace default via "$gw" dev "$iface" 2>/dev/null
            "$_DI_RM" -f "$f"
        fi
        printf 'restored default routes for %s\n' "$iface"
        return 0
    fi

    # No argument: revert everything default_iface touched.
    local any=false
    for f in "$_DEFAULT_IFACE_STATE_DIR"/*.orig; do
        [ -f "$f" ] || continue
        uuid=${f##*/}; uuid=${uuid%.orig}
        _default_iface_restore_con "$uuid"; any=true
    done
    for f in "$_DEFAULT_IFACE_STATE_DIR"/*.manualblock; do
        [ -f "$f" ] || continue
        ifn=${f##*/}; ifn=${ifn%.manualblock}
        gw=$("$_DI_CAT" "$f")
        [ -n "$gw" ] && "$_DI_IP" route replace default via "$gw" dev "$ifn" 2>/dev/null
        "$_DI_RM" -f "$f"; any=true
    done
    _default_iface_restore_dns
    "$_DI_RM" -f "$_DEFAULT_IFACE_STATE_DIR/preferred"
    $any && printf 'restored all interfaces modified by default_iface\n' \
         || printf 'default_iface_restore: nothing to restore\n'
}

default_iface_status() {
    local iface mgmt egress puuid

    _default_iface_have_ip || return 1

    printf 'preferred: '
    if [ -f "$_DEFAULT_IFACE_STATE_DIR/preferred" ]; then
        "$_DI_CAT" "$_DEFAULT_IFACE_STATE_DIR/preferred"; printf '\n'
    else
        printf '(none)\n'
    fi

    printf '\n%-8s %-14s %s\n' IFACE MANAGED-BY DEFAULT-ROUTE
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        if _default_iface_nm_manages_ipv4 "$iface"; then mgmt="NetworkManager"; else mgmt="manual/route"; fi
        printf '%-8s %-14s %s\n' "$iface" "$mgmt" \
            "$("$_DI_IP" -4 route show default dev "$iface" 2>/dev/null | "$_DI_HEAD" -1)"
    done < <(_default_iface_candidate_ifaces)

    printf '\ndefault routes:\n'
    "$_DI_IP" route show default 2>/dev/null | "$_DI_SED" 's/^/  /'
    [ -n "$("$_DI_IP" route show default 2>/dev/null)" ] || printf '  (none — failing closed)\n'

    egress=$(_default_iface_egress_dev)
    printf '\negress -> 8.8.8.8: %s\n' "${egress:-no route (failing closed)}"
    printf 'resolv.conf: %s\n' "$("$_DI_GREP" -m1 nameserver /etc/resolv.conf 2>/dev/null || echo '(none)')"
}
