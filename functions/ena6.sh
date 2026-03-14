ena6() {
    rm -f /etc/sysctl.d/99-disable-ipv6.conf
    sysctl --system
}
