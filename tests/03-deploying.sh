#!/usr/bin/env bash
# Is the file valid, does the cluster match it, and do settings survive a restart?
# NOTE: restarts Pi-hole once (home network DNS pauses for a few seconds).
source "$(dirname "$0")/lib.sh"
echo "== 03 Deploying"

check "manifest is valid (server dry-run)" kubectl apply --dry-run=server -f "$ROOT/pihole.yaml"
# kubectl diff returns 0 when the cluster matches the file exactly
check "cluster matches the file (no drift)" kubectl diff -f "$ROOT/pihole.yaml"

# Block a domain, restart Pi-hole, check it is still blocked and the password still works
P=dnstestp.example.com
cleanup() { is_denied "$P" && deny_remove "$P" >/dev/null 2>&1; }
trap 'cleanup; client_stop' EXIT
client_start
cleanup

deny_add "$P" >/dev/null
sleep 2   # Pi-hole applies list changes within a second

echo "  ...restarting Pi-hole"
kubectl rollout restart deployment/pihole -n "$NS" >/dev/null
check "Pi-hole comes back Ready after restart" \
  kubectl rollout status deployment/pihole -n "$NS" --timeout=180s
check "DNS works after restart"          resolves example.com
check "blocked domains survive a restart" is_blocked "$P"
check "password survives a restart"      api GET /api/info/version

finish
