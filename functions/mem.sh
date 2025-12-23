mem () {                                   # usage: mem <partial-name>
    local pat="$1"
    printf "%-7s %9s  %s\n" PID "RSS(MB)" CMD
    ps -eo pid,rss,comm --no-headers |                     # pid + rss (KiB) + cmd
    awk -v pat="$(printf '%s' "$pat" | tr '[:upper:]' '[:lower:]')" '
        {cmd = tolower($3)}
        cmd ~ pat {
            mb = $2 / 1024
            printf "%-7d %9.2f  %s\n", $1, mb, $3
            total += mb
        }
        END {if (total) printf "TOTAL:  %.2f MB\n", total}
    '
}
