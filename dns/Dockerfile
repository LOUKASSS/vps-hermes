# Tiny authoritative-only DNS for the tailnet: dnsmasq on Alpine (patched with every weekly
# `compose build --pull`). Answers A for DNS_ZONE and everything under it with DNS_IP, nothing else.
FROM alpine:3
RUN apk add --no-cache dnsmasq
COPY dnsmasq.conf /etc/dnsmasq.conf
COPY entrypoint.sh /entrypoint.sh
EXPOSE 53/udp 53/tcp
ENTRYPOINT ["/entrypoint.sh"]
