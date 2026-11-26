#!/bin/sh
# Starts the OpenVPN server: validates the environment, renders the config,
# sets up forwarding/NAT inside the container's own network namespace, then
# hands over to openvpn.
#
#   entrypoint.sh            run the server
#   entrypoint.sh --check    validate the environment and print the rendered
#                            config; touches no network state, needs no PKI
set -eu

. /usr/local/lib/openvpn-compose/lib.sh

VPN_SUBNET=${VPN_SUBNET:-172.16.80.0/24}
VPN_DNS=${VPN_DNS-1.1.1.1,1.0.0.1}
VPN_REDIRECT_GATEWAY=${VPN_REDIRECT_GATEWAY:-true}

mode=run
case "${1:-}" in
    "") ;;
    --check) mode=check ;;
    *) die "usage: entrypoint.sh [--check]" ;;
esac
[ "$#" -le 1 ] || die "usage: entrypoint.sh [--check]"

parse_subnet "$VPN_SUBNET"
validate_bool VPN_REDIRECT_GATEWAY "$VPN_REDIRECT_GATEWAY"
validate_dns_list "$VPN_DNS"

CONF=/tmp/server.conf
cp /etc/openvpn/server.conf "$CONF"
{
    echo
    echo "# Rendered from the environment"
    echo "server $SUBNET_NET $SUBNET_MASK"
    if [ "$VPN_REDIRECT_GATEWAY" = true ]; then
        echo 'push "redirect-gateway def1"'
    fi
    if [ -n "$VPN_DNS" ]; then
        _oldifs=$IFS
        IFS=,
        for dns in $VPN_DNS; do
            echo "push \"dhcp-option DNS $dns\""
        done
        IFS=$_oldifs
    fi
} >>"$CONF"

if [ "$mode" = check ]; then
    openvpn --version | head -n 1
    cat "$CONF"
    exit 0
fi

for required in ca.crt server.crt server.key tls-crypt.key; do
    [ -s "/etc/openvpn/pki/$required" ] ||
        die "missing or empty /etc/openvpn/pki/$required (did the init service run?)"
done

[ -c /dev/net/tun ] ||
    die "/dev/net/tun is missing; add 'devices: [/dev/net/tun]' and cap NET_ADMIN"

WAN_IF=$(ip -4 route get 1.1.1.1 | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }')
[ -n "$WAN_IF" ] || die "cannot determine the outbound network interface"

if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != 1 ]; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 ||
        die "net.ipv4.ip_forward is off and cannot be changed; set 'sysctls: net.ipv4.ip_forward=1' in compose"
fi

# These rules live in the container's own network namespace. Check before
# inserting so a container restart never duplicates them.
VPN_CIDR="$SUBNET_NET/$SUBNET_PREFIX"
if ! iptables -C FORWARD -i tun0 -o "$WAN_IF" -s "$VPN_CIDR" -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD 1 -i tun0 -o "$WAN_IF" -s "$VPN_CIDR" -j ACCEPT
fi
if ! iptables -C FORWARD -i "$WAN_IF" -o tun0 -d "$VPN_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD 1 -i "$WAN_IF" -o tun0 -d "$VPN_CIDR" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fi
if ! iptables -t nat -C POSTROUTING -s "$VPN_CIDR" -o "$WAN_IF" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$VPN_CIDR" -o "$WAN_IF" -j MASQUERADE
fi

exec openvpn --config "$CONF"
