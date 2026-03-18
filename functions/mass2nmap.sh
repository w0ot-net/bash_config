mass2nmap() {
    local file="$1"
    [[ -f "$file" ]] || { echo "usage: mass2nmap <masscan_output.txt>" >&2; return 1; }
    local ports hostfile
    ports=$(awk '/^Timestamp/{split($7,p,"/"); a[p[1]]}END{for(k in a) printf "%s,",k}' "$file" | sed 's/,$//')
    hostfile="/tmp/mass2nmap_hosts_$$.txt"
    awk '/^Timestamp/{a[$4]}END{for(k in a) print k}' "$file" > "$hostfile"
    echo "nmap -sV -Pn -p $ports -iL $hostfile"
}
