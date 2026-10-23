#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
kernel="$PWD/kernel/vmlinux-native-wireguard"
case "${1:-test}" in
  up)
    test -f "$kernel"
    for node in a b; do
      container run -d --name "wg-test-$node" --kernel "$kernel" alpine:3.22 sleep infinity
      container exec "wg-test-$node" sh -ec 'apk add --no-cache wireguard-tools iproute2 iputils curl; umask 077; mkdir -p /etc/wireguard; wg genkey > /etc/wireguard/private; wg pubkey < /etc/wireguard/private > /etc/wireguard/public'
    done
    ./lab.sh configure
    ;;
  configure)
    a_ip=$(container exec wg-test-a sh -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1")
    b_ip=$(container exec wg-test-b sh -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1")
    a_pub=$(container exec wg-test-a cat /etc/wireguard/public)
    b_pub=$(container exec wg-test-b cat /etc/wireguard/public)
    setup() {
      container exec "wg-test-$1" sh -ec '
        ip link show wg0 >/dev/null 2>&1 || ip link add wg0 type wireguard
        ip address replace "$1/32" dev wg0
        wg set wg0 listen-port 51820 private-key /etc/wireguard/private peer "$3" allowed-ips "$2/32" endpoint "$4:51820" persistent-keepalive 5
        ip link set wg0 mtu 1420 up
        ip route replace "$2/32" dev wg0
        umask 077
        wg showconf wg0 > /etc/wireguard/wg0.conf
      ' sh "$2" "$3" "$4" "$5"
    }
    setup a 10.77.0.1 10.77.0.2 "$b_pub" "$b_ip"
    setup b 10.77.0.2 10.77.0.1 "$a_pub" "$a_ip"
    ;;
  test)
    container exec wg-test-a ping -c 3 -W 3 10.77.0.2
    container exec wg-test-b ping -c 3 -W 3 10.77.0.1
    for node in a b; do
      container exec "wg-test-$node" sh -ec 'zcat /proc/config.gz | grep -x CONFIG_WIREGUARD=y; ip -d link show wg0'
      container exec "wg-test-$node" wg show
      container exec "wg-test-$node" sh -ec 'wg show wg0 latest-handshakes | awk "\$2 > 0 {ok=1} END {exit !ok}"'
    done
    ;;
  down)
    for node in a b; do container stop "wg-test-$node"; container delete "wg-test-$node"; done
    ;;
  *) echo 'Usage: ./lab.sh {up|configure|test|down}' >&2; exit 2 ;;
esac
