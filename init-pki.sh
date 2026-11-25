#!/bin/sh
# Creates whatever PKI material and client profiles are missing, and leaves
# everything that already exists untouched, so it is safe to run on every
# 'docker compose up'.
#
# Layout under $DATA_DIR (default /data, bind-mounted from ./data):
#   ca/        ca.crt, ca.key                     CA (private key never leaves here)
#   server/    ca.crt, server.crt, server.key,    the only directory the server
#              tls-crypt.key                      container gets (read-only)
#   clients/   <name>.crt, <name>.key, <name>.ovpn
set -eu
umask 077

. /usr/local/lib/openvpn-compose/lib.sh

VPN_HOST=${VPN_HOST:-}
VPN_PORT=${VPN_PORT:-1194}
VPN_CLIENTS=${VPN_CLIENTS:-vpn-client}
VPN_CERT_DAYS=${VPN_CERT_DAYS:-3650}
DATA_DIR=${DATA_DIR:-/data}

CA_DIR=$DATA_DIR/ca
SERVER_DIR=$DATA_DIR/server
CLIENT_DIR=$DATA_DIR/clients
CA_CRT=$CA_DIR/ca.crt
CA_KEY=$CA_DIR/ca.key

# 2038-01-01T00:00:00Z. Certificates that expire after this can break 32-bit
# clients (for example older routers), so we refuse to issue them.
LIMIT_EPOCH=2145916800
RENEW_BEFORE=2592000 # 30 days, in seconds

log() { echo "init: $*" >&2; }

# ---------------------------------------------------------------- validation
[ -n "$VPN_HOST" ] || die "VPN_HOST is not set; put it in .env (see .env.example)"
case "$VPN_HOST" in
    *[!A-Za-z0-9.-]*) die "VPN_HOST may only contain letters, digits, '.' and '-' (got '$VPN_HOST')" ;;
esac

case "$VPN_PORT" in
    "" | *[!0-9]*) die "VPN_PORT must be a number (got '$VPN_PORT')" ;;
esac
{ [ "$VPN_PORT" -ge 1 ] && [ "$VPN_PORT" -le 65535 ]; } || die "VPN_PORT must be between 1 and 65535"

case "$VPN_CERT_DAYS" in
    "" | *[!0-9]*) die "VPN_CERT_DAYS must be a positive integer (got '$VPN_CERT_DAYS')" ;;
esac
[ "$VPN_CERT_DAYS" -ge 1 ] || die "VPN_CERT_DAYS must be at least 1"
NOW=$(date +%s)
MAX_DAYS=$(((LIMIT_EPOCH - NOW) / 86400 - 1))
[ "$VPN_CERT_DAYS" -le "$MAX_DAYS" ] ||
    die "VPN_CERT_DAYS=$VPN_CERT_DAYS would expire after 2037; the maximum today is $MAX_DAYS"

# Normalise the client list: split on commas, drop blanks and spaces.
CLIENT_NAMES=
_oldifs=$IFS
IFS=,
for _name in $VPN_CLIENTS; do
    _name=$(echo "$_name" | tr -d '[:space:]')
    [ -n "$_name" ] || continue
    case "$_name" in
        *[!A-Za-z0-9_-]*) IFS=$_oldifs; die "client name '$_name' may only contain letters, digits, '-' and '_'" ;;
    esac
    [ "${#_name}" -le 64 ] || { IFS=$_oldifs; die "client name '$_name' is longer than 64 characters"; }
    CLIENT_NAMES="$CLIENT_NAMES $_name"
done
IFS=$_oldifs
[ -n "$CLIENT_NAMES" ] || die "VPN_CLIENTS must name at least one client"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$CA_DIR" "$SERVER_DIR" "$CLIENT_DIR"
chmod 700 "$DATA_DIR" "$CA_DIR" "$SERVER_DIR" "$CLIENT_DIR"

# ------------------------------------------------------------------- helpers
need_ca_key() {
    [ -s "$CA_KEY" ] ||
        die "need to issue a certificate but $CA_KEY is missing; restore it (or delete data/ to start over)"
}

# cert_matches_key <crt> <key>: the certificate belongs to the private key.
cert_matches_key() {
    [ "$(openssl x509 -pubkey -noout -in "$1" | sha256sum)" = "$(openssl pkey -pubout -in "$2" | sha256sum)" ]
}

# days_for_new_cert: VPN_CERT_DAYS, capped so a certificate never outlives the CA.
days_for_new_cert() {
    _end=$(openssl x509 -noout -enddate -in "$CA_CRT" | cut -d= -f2)
    _end_epoch=$(date -u -D '%b %e %H:%M:%S %Y' -d "${_end% GMT}" +%s)
    _left=$(((_end_epoch - $(date +%s)) / 86400 - 1))
    [ "$_left" -ge 1 ] || die "the CA expires in less than two days; delete data/ to start over with a new CA"
    if [ "$_left" -lt "$VPN_CERT_DAYS" ]; then
        # A day or two of difference is normal (the CA was created moments
        # before the first certificate); only mention a meaningful cap.
        if [ $((VPN_CERT_DAYS - _left)) -gt 7 ]; then
            log "NOTE: the CA expires sooner than VPN_CERT_DAYS; issuing for $_left days instead"
        fi
        echo "$_left"
    else
        echo "$VPN_CERT_DAYS"
    fi
}

# issue_cert <key-out> <crt-out> <common-name> <ext-file>
issue_cert() {
    need_ca_key
    _days=$(days_for_new_cert)
    openssl req -newkey rsa:3072 -noenc -keyout "$TMP/new.key" -out "$TMP/new.csr" \
        -subj "/CN=$3" >/dev/null 2>&1
    openssl x509 -req -in "$TMP/new.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
        -set_serial "0x$(openssl rand -hex 16)" -out "$TMP/new.crt" \
        -days "$_days" -extfile "$4" >/dev/null 2>&1
    mv "$TMP/new.key" "$1"
    mv "$TMP/new.crt" "$2"
    rm -f "$TMP/new.csr"
}

# ------------------------------------------------------------------------ CA
if [ ! -s "$CA_CRT" ] && [ ! -s "$CA_KEY" ]; then
    log "creating CA"
    openssl req -x509 -newkey rsa:3072 -noenc -keyout "$CA_KEY" -out "$CA_CRT" \
        -days "$VPN_CERT_DAYS" -subj /CN=openvpn-compose-CA \
        -addext basicConstraints=critical,CA:TRUE \
        -addext keyUsage=critical,keyCertSign,cRLSign >/dev/null 2>&1
elif [ ! -s "$CA_CRT" ]; then
    die "$CA_KEY exists but $CA_CRT is missing; restore it (or delete data/ to start over)"
fi
if [ -s "$CA_KEY" ] && ! cert_matches_key "$CA_CRT" "$CA_KEY"; then
    die "$CA_CRT and $CA_KEY do not belong together"
fi

# ----------------------------------------------------------------- tls-crypt
TLS_KEY=$SERVER_DIR/tls-crypt.key
if [ ! -s "$TLS_KEY" ]; then
    log "creating tls-crypt key"
    openvpn --genkey tls-crypt "$TMP/tls-crypt.key" >/dev/null 2>&1
    [ -s "$TMP/tls-crypt.key" ] || die "could not generate the tls-crypt key"
    mv "$TMP/tls-crypt.key" "$TLS_KEY"
fi

# -------------------------------------------------------------- server cert
cat >"$TMP/server.ext" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:openvpn-server
EOF
cat >"$TMP/client.ext" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
EOF

SERVER_CRT=$SERVER_DIR/server.crt
SERVER_KEY=$SERVER_DIR/server.key
reissue_server=false
if [ ! -s "$SERVER_CRT" ] || [ ! -s "$SERVER_KEY" ]; then
    reissue_server=true
elif ! openssl verify -CAfile "$CA_CRT" -purpose sslserver "$SERVER_CRT" >/dev/null 2>&1 ||
    ! cert_matches_key "$SERVER_CRT" "$SERVER_KEY" ||
    ! openssl x509 -checkend "$RENEW_BEFORE" -noout -in "$SERVER_CRT" >/dev/null; then
    log "server certificate is invalid or expires within 30 days; reissuing"
    reissue_server=true
fi
if [ "$reissue_server" = true ]; then
    log "issuing server certificate"
    issue_cert "$SERVER_KEY" "$SERVER_CRT" openvpn-server "$TMP/server.ext"
fi
cp "$CA_CRT" "$SERVER_DIR/ca.crt"

# ------------------------------------------------------------- client certs
for name in $CLIENT_NAMES; do
    crt=$CLIENT_DIR/$name.crt
    key=$CLIENT_DIR/$name.key
    if [ ! -s "$crt" ] && [ ! -s "$key" ]; then
        log "issuing certificate for client '$name'"
        issue_cert "$key" "$crt" "$name" "$TMP/client.ext"
    elif [ ! -s "$crt" ] || [ ! -s "$key" ]; then
        die "client '$name' has only one of $name.crt / $name.key in data/clients; delete the leftover to regenerate"
    else
        openssl verify -CAfile "$CA_CRT" -purpose sslclient "$crt" >/dev/null 2>&1 ||
            die "certificate for client '$name' does not verify against the CA (was the CA replaced?)"
        cert_matches_key "$crt" "$key" ||
            die "certificate and key for client '$name' do not belong together"
        if ! openssl x509 -checkend "$RENEW_BEFORE" -noout -in "$crt" >/dev/null; then
            log "WARNING: the certificate for client '$name' has expired or expires within 30 days;" \
                "delete data/clients/$name.* and run again to issue a new one (then re-import its profile)"
        fi
    fi
done

# ---------------------------------------------------------- client profiles
# The profile is deterministic, so rewriting it only when it differs keeps
# repeated runs from touching files (and tells you when a setting changed it).
for name in $CLIENT_NAMES; do
    profile=$CLIENT_DIR/$name.ovpn
    {
        echo client
        echo dev tun
        echo proto udp4
        echo "remote $VPN_HOST $VPN_PORT"
        echo nobind
        echo persist-key
        echo persist-tun
        echo remote-cert-tls server
        # 'ncp-ciphers' (not 'data-ciphers') so older clients such as router
        # firmware still understand the profile.
        echo ncp-ciphers AES-256-GCM:AES-128-GCM
        echo auth SHA256
        echo verb 3
        for pair in ca:"$CA_CRT" cert:"$CLIENT_DIR/$name.crt" key:"$CLIENT_DIR/$name.key" tls-crypt:"$TLS_KEY"; do
            echo "<${pair%%:*}>"
            awk '1' "${pair#*:}"
            echo "</${pair%%:*}>"
        done
    } >"$TMP/$name.ovpn"
    if [ ! -f "$profile" ]; then
        log "writing profile for client '$name'"
    elif ! cmp -s "$TMP/$name.ovpn" "$profile"; then
        log "updating profile for client '$name' (its settings changed; re-import it on the device)"
    else
        continue
    fi
    mv "$TMP/$name.ovpn" "$profile"
done

# ------------------------------------------------------------------- checks
for private in ca.key; do
    [ ! -e "$SERVER_DIR/$private" ] || die "refusing to continue: $private ended up in the server directory"
done
for name in $CLIENT_NAMES; do
    [ ! -e "$SERVER_DIR/$name.key" ] || die "refusing to continue: a client key ended up in the server directory"
done

log "ready. Client profiles:"
for name in $CLIENT_NAMES; do
    log "  data/clients/$name.ovpn"
done
