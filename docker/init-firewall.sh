#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Snapshot Docker's internal DNS NAT rules before flushing anything
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush all existing rules and ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Restore Docker's internal DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# Protocol-level rules (set before the default-DROP policy)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT  -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Build the allowlist
ipset create allowed-domains hash:net

# GitHub IP ranges — covers api.github.com, github.com, raw content, AND ghcr.io (packages)
# ghcr.io (Trivy vulnerability DB) lives under the packages CIDR block
gh_ranges=$(curl -s https://api.github.com/meta)
while read -r cidr; do
  ipset add allowed-domains "$cidr" 2>/dev/null || true
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git + .packages)[]' | aggregate -q)

# Resolve each domain to IPs at startup and add to the allowlist
for domain in \
  "registry.npmjs.org" \
  "api.anthropic.com" \
  "statsig.anthropic.com" \
  "statsig.com" \
  "sentry.io" \
  "app.codacy.com" \
  "api.codacy.com" \
  "generativelanguage.googleapis.com" \
  "oauth2.googleapis.com" \
  "cveawg.mitre.org" \
  "api.osv.dev" \
  "pypi.org" \
  "files.pythonhosted.org" \
  "pkg-containers.githubusercontent.com" \
  "bc-api.bridgecrew.io" \
  "bc-api.prismacloud.io" \
  "cdn.prismacloud.io"; do
  for _ in 1 2 3 4 5; do
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" { print $5 }')
    while read -r ip; do
      [ -n "$ip" ] && ipset add allowed-domains "$ip" 2>/dev/null || true
    done <<< "$ips"
  done
done

# Allow the host network (the Docker host machine)
HOST_IP=$(ip route | grep default | cut -d" " -f3)
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
iptables -A INPUT  -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Default-deny all chains
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# Allow established/related return traffic
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow outbound to the allowlist only
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Log blocked connections before rejecting (readable via /dev/kmsg)
iptables -A OUTPUT -j LOG --log-prefix "[FW_BLOCK] " --log-level 4

# Reject everything else immediately (no silent timeouts)
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# Sanity checks
curl --connect-timeout 5 https://example.com >/dev/null 2>&1 && { echo "FIREWALL ERROR: example.com should be blocked"; exit 1; }
curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1 || { echo "FIREWALL ERROR: api.github.com should be reachable"; exit 1; }
curl --connect-timeout 5 https://api.anthropic.com >/dev/null 2>&1 || true  # 401 is fine, blocked is not
curl --connect-timeout 5 https://app.codacy.com >/dev/null 2>&1 || { echo "FIREWALL ERROR: app.codacy.com should be reachable"; exit 1; }

echo "Firewall initialized."

# Emit blocked outbound connections to stderr in real time.
# /dev/kmsg must be mapped into the container: --device /dev/kmsg:/dev/kmsg
if [ -r /dev/kmsg ]; then
  (
    grep --line-buffered "FW_BLOCK" /dev/kmsg 2>/dev/null | \
    while IFS= read -r line; do
      msg="${line#*;}"
      dst=$(printf '%s' "$msg" | grep -oE 'DST=[0-9.]+' | cut -d= -f2)
      dpt=$(printf '%s' "$msg" | grep -oE 'DPT=[0-9]+' | cut -d= -f2)
      proto=$(printf '%s' "$msg" | grep -oE 'PROTO=[A-Z]+' | cut -d= -f2)
      if [ -n "$dst" ]; then
        hostname=$(dig -x "$dst" +short 2>/dev/null | sed 's/\.$//' | head -1)
        if [ -n "$hostname" ]; then
          printf '[firewall] blocked: %s %s (%s):%s\n' "${proto:-?}" "$dst" "$hostname" "${dpt:-?}" >&2
        else
          printf '[firewall] blocked: %s %s:%s\n' "${proto:-?}" "$dst" "${dpt:-?}" >&2
        fi
      fi
    done
  ) &
  echo "Firewall block monitor started."
else
  echo "Note: /dev/kmsg not mapped — blocked connections won't be logged to stderr. Add --device /dev/kmsg:/dev/kmsg to docker run." >&2
fi
