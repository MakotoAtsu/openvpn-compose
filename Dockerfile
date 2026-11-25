FROM alpine:3.22

RUN apk add --no-cache openvpn iptables iproute2

COPY lib.sh /usr/local/lib/openvpn-compose/lib.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY server.conf /etc/openvpn/server.conf

RUN chmod 755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
