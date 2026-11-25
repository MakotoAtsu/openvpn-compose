FROM alpine:3.22

RUN apk add --no-cache openvpn iptables iproute2 openssl

COPY lib.sh /usr/local/lib/openvpn-compose/lib.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY init-pki.sh /usr/local/bin/init-pki.sh
COPY server.conf /etc/openvpn/server.conf

RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/init-pki.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
