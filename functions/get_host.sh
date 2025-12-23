get_host() {
    local input="$1"

    _lookup() {
        local ip
        ip=$(nslookup "$1" 2>/dev/null | awk '$1 == "Address:" && index($2, "#") == 0 {print $2; exit}')
        [[ -n "$ip" ]] && echo "$ip" || echo "lookup failed"
    }

    if [[ -f "$input" ]]; then
        while IFS= read -r host || [[ -n "$host" ]]; do
            echo "$host: $(_lookup "$host")"
        done < "$input"
    else
        _lookup "$input"
    fi
}
