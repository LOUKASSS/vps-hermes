#!/bin/sh
# DNS_ZONE (e.g. hermes.example.com) and DNS_IP (the VPS Tailscale IP) come from compose.
set -eu
[ -n "${DNS_ZONE:-}" ] && [ -n "${DNS_IP:-}" ] || { echo "DNS_ZONE and DNS_IP are required" >&2; exit 1; }
mkdir -p /etc/dnsmasq.d
{
  # address=: A (and, for a v4 address, empty AAAA) for the zone apex and every name under it.
  echo "address=/$DNS_ZONE/$DNS_IP"
  # local=: never forward the zone (we have no upstream anyway).
  echo "local=/$DNS_ZONE/"
} > /etc/dnsmasq.d/zone.conf
exec dnsmasq --keep-in-foreground --log-facility=- --conf-file=/etc/dnsmasq.conf
