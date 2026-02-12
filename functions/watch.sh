watch() {
    local flags=()
    while [[ $# -gt 0 && "$1" == -* ]]; do
        flags+=("$1")
        case "$1" in
            -n|--interval|-q|--equexit|-d|--differences) shift; flags+=("$1") ;;
        esac
        shift
    done
    command watch "${flags[@]}" bash -c "$*"
}
