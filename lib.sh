#!/bin/sh
# Shared helpers, sourced by entrypoint.sh and init-pki.sh (POSIX sh / busybox ash).

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# is_ipv4 <string>: succeeds for a dotted-quad IPv4 address (no leading zeros).
is_ipv4() {
    case "$1" in
        "" | *[!0-9.]* | .* | *. | *..*) return 1 ;;
    esac
    _oldifs=$IFS
    IFS=.
    set -- $1
    IFS=$_oldifs
    [ "$#" -eq 4 ] || return 1
    for _octet in "$@"; do
        case "$_octet" in
            0?*) return 1 ;;
        esac
        [ "${#_octet}" -le 3 ] && [ "$_octet" -le 255 ] || return 1
    done
}

# parse_subnet <cidr>: validates the CIDR and sets
#   SUBNET_NET (network address), SUBNET_MASK (dotted netmask), SUBNET_PREFIX.
parse_subnet() {
    _cidr=$1
    case "$_cidr" in
        */*) ;;
        *) die "VPN_SUBNET must be a CIDR such as 172.16.88.0/24 (got '$_cidr')" ;;
    esac
    _addr=${_cidr%/*}
    _prefix=${_cidr#*/}
    is_ipv4 "$_addr" || die "VPN_SUBNET has an invalid IPv4 address: '$_addr'"
    case "$_prefix" in
        "" | *[!0-9]*) die "VPN_SUBNET has an invalid prefix length: '$_prefix'" ;;
    esac
    { [ "$_prefix" -ge 8 ] && [ "$_prefix" -le 29 ]; } ||
        die "VPN_SUBNET prefix length must be between 8 and 29 (got $_prefix)"

    _oldifs=$IFS
    IFS=.
    set -- $_addr
    IFS=$_oldifs
    _rem=$_prefix
    _mask=
    _net=
    for _octet in "$@"; do
        if [ "$_rem" -ge 8 ]; then
            _m=255
            _rem=$((_rem - 8))
        elif [ "$_rem" -gt 0 ]; then
            _m=$((256 - (1 << (8 - _rem))))
            _rem=0
        else
            _m=0
        fi
        _mask="${_mask:+$_mask.}$_m"
        _net="${_net:+$_net.}$((_octet & _m))"
    done
    SUBNET_NET=$_net
    SUBNET_MASK=$_mask
    SUBNET_PREFIX=$_prefix
    if [ "$_net" != "$_addr" ]; then
        echo "NOTE: VPN_SUBNET $_cidr is not a network address; using $_net/$_prefix" >&2
    fi
}

# validate_bool <name> <value>: only 'true' or 'false' are accepted.
validate_bool() {
    case "$2" in
        true | false) ;;
        *) die "$1 must be 'true' or 'false' (got '$2')" ;;
    esac
}

# validate_dns_list <comma separated list>: empty is allowed.
validate_dns_list() {
    [ -n "$1" ] || return 0
    _oldifs=$IFS
    IFS=,
    for _dns in $1; do
        is_ipv4 "$_dns" || {
            IFS=$_oldifs
            die "VPN_DNS contains an invalid IPv4 address: '$_dns'"
        }
    done
    IFS=$_oldifs
}
