restart_vbox() {
    local launcher="${VBOX_XSESSION_LAUNCHER:-/etc/X11/Xsession.d/98vboxadd-xclient}"
    local virtualizer service status mode pid_file session_type
    local -a installed_services=() restart_command=() modes=()

    command -v systemd-detect-virt >/dev/null 2>&1 || {
        printf 'restart_vbox: systemd-detect-virt not found\n' >&2
        return 1
    }
    virtualizer=$(command systemd-detect-virt --vm 2>/dev/null) || virtualizer=""
    if [[ "$virtualizer" != "oracle" ]]; then
        printf 'restart_vbox: not a VirtualBox guest; nothing to restart\n'
        return 0
    fi

    session_type="${XDG_SESSION_TYPE:-}"
    if [[ "${session_type,,}" == "wayland" || -n "${WAYLAND_DISPLAY:-}" ]]; then
        printf '%s\n' \
            'restart_vbox: the Wayland client combines clipboard and drag and drop; X11 is required' >&2
        return 1
    fi
    [[ -n "${DISPLAY:-}" ]] || {
        printf '%s\n' \
            'restart_vbox: run this from a terminal inside the X11 desktop session' >&2
        return 1
    }

    command -v systemctl >/dev/null 2>&1 || {
        printf 'restart_vbox: systemctl not found\n' >&2
        return 1
    }
    command -v pkill >/dev/null 2>&1 || {
        printf 'restart_vbox: pkill not found\n' >&2
        return 1
    }
    command -v VBoxClient >/dev/null 2>&1 || {
        printf 'restart_vbox: VBoxClient not found\n' >&2
        return 1
    }
    command -v awk >/dev/null 2>&1 || {
        printf 'restart_vbox: awk not found\n' >&2
        return 1
    }
    [[ -r "$launcher" ]] || {
        printf 'restart_vbox: cannot read %s\n' "$launcher" >&2
        return 1
    }

    while IFS= read -r mode; do
        [[ -n "$mode" ]] && modes+=("$mode")
    done < <(
        command awk '
            /^[[:space:]]*#/ { next }
            {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /(^|\/)VBoxClient$/ && $(i + 1) ~ /^--[[:alnum:]-]+$/) {
                        mode = substr($(i + 1), 3)
                        if (mode != "draganddrop" && mode != "wayland" && !seen[mode]++)
                            print mode
                    }
                }
            }
        ' "$launcher"
    )
    ((${#modes[@]} > 0)) || {
        printf 'restart_vbox: no safe VBoxClient modes found in %s\n' "$launcher" >&2
        return 1
    }

    for service in virtualbox-guest-utils.service vboxadd-service.service; do
        if command systemctl cat "$service" >/dev/null 2>&1; then
            installed_services+=("$service")
        fi
    done

    if ((${#installed_services[@]} > 0)); then
        if ((EUID == 0)); then
            restart_command=(systemctl restart)
        else
            command -v sudo >/dev/null 2>&1 || {
                printf 'restart_vbox: sudo not found\n' >&2
                return 1
            }
            restart_command=(sudo systemctl restart)
        fi

        for service in "${installed_services[@]}"; do
            command "${restart_command[@]}" "$service" || {
                printf 'restart_vbox: failed to restart %s\n' "$service" >&2
                return 1
            }
        done
    else
        printf '%s\n' \
            'restart_vbox: no supported guest service unit found; restarting desktop clients only' >&2
    fi

    if command pkill -u "$EUID" -x VBoxClient; then
        :
    else
        status=$?
        if ((status != 1)); then
            printf 'restart_vbox: failed to stop VBoxClient processes\n' >&2
            return 1
        fi
    fi
    command sleep 1

    for pid_file in "$HOME"/.vboxclient-*.pid; do
        [[ -e "$pid_file" || -L "$pid_file" ]] || continue
        command rm -f -- "$pid_file" || {
            printf 'restart_vbox: failed to remove %s\n' "$pid_file" >&2
            return 1
        }
    done

    for mode in "${modes[@]}"; do
        command VBoxClient "--$mode" || {
            printf 'restart_vbox: failed to start VBoxClient --%s\n' "$mode" >&2
            return 1
        }
    done

    printf 'restart_vbox: restarted services and VBoxClient modes: %s\n' "${modes[*]}"
}
