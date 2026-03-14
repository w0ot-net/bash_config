kill6() {
    printf "net.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\nnet.ipv6.conf.all.accept_ra=0\nnet.ipv6.conf.default.accept_ra=0\n" > /etc/sysctl.d/99-disable-ipv6.conf
    sysctl --system
}
