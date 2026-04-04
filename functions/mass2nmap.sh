mass2nmap() {
    local file="$1"
    [[ -f "$file" ]] || { echo "usage: mass2nmap <masscan_output>" >&2; return 1; }
    local ports hostfile
    hostfile="/tmp/mass2nmap_hosts_$$.txt"
    if head -1 "$file" | grep -q '<?xml'; then
        ports=$(awk -F'"' '/portid=/{a[$0]; for(i=1;i<=NF;i++) if($(i-1)~/portid=$/) p[$i]} END{for(k in p) printf "%s,",k}' "$file" | sed 's/,$//')
        awk -F'"' '/addr=/{for(i=1;i<=NF;i++) if($(i-1)~/addr=$/) a[$i]} END{for(k in a) print k}' "$file" > "$hostfile"
    else
        ports=$(awk '/^Timestamp/{split($7,p,"/"); a[p[1]]}END{for(k in a) printf "%s,",k}' "$file" | sed 's/,$//')
        awk '/^Timestamp/{a[$4]}END{for(k in a) print k}' "$file" > "$hostfile"
    fi
    echo "nmap -sV -Pn -p $ports -iL $hostfile"
}
