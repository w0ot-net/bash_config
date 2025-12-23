affected_systems() {
    local input="$1"
    local port="$2"
    local service="$3"

    if [[ -z "$input" || -z "$port" ]]; then
        echo "usage: affected_systems <ip|host|file> <port> [service]" >&2
        return 1
    fi

    if [[ -z "$service" ]]; then
        service=$(getent services "${port}/tcp" 2>/dev/null | awk 'NR==1 {print $1}')
    fi
    [[ -z "$service" ]] && service="-"

    _resolve_ip_from_host() {
        nslookup "$1" 2>/dev/null | awk '$1 == "Address:" && index($2, "#") == 0 {print $2; exit}'
    }

    _reverse_name_from_ip() {
        nslookup "$1" 2>/dev/null | awk -F'= ' '/name =/ {print $2; exit}' | sed 's/\.$//'
    }

    _emit_line() {
        local target="$1"
        local ip
        local name

        if [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            ip="$target"
            name="$(_reverse_name_from_ip "$target")"
            [[ -z "$name" ]] && name="-"
        else
            name="$target"
            ip="$(_resolve_ip_from_host "$target")"
            [[ -z "$ip" ]] && ip="-"
        fi

        printf '%s,%s,%s (%s/tcp)\n' "$ip" "$name" "$service" "$port"
    }

    if [[ -f "$input" ]]; then
        while IFS= read -r target || [[ -n "$target" ]]; do
            [[ -z "$target" ]] && continue
            _emit_line "$target"
        done < "$input"
    else
        _emit_line "$input"
    fi
}
