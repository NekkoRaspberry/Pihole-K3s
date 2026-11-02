#!/usr/bin/env bash
# Is Pi-hole running, protected and answering DNS? (changes nothing)
source "$(dirname "$0")/lib.sh"
echo "== 01 Running"

trap client_stop EXIT
client_start
POD="$(pihole_pod)"
LAN="$(lan_ip)"

check "Pi-hole pod is Ready" \
  kubectl wait -n "$NS" --for=condition=Ready "pod/$POD" --timeout=10s
check "storage (PVC) is Bound" \
  test "$(kubectl get pvc -n "$NS" pihole-data -o jsonpath='{.status.phase}')" = Bound
check "web UI is internal only (ClusterIP)" \
  test "$(kubectl get svc -n "$NS" pihole-web -o jsonpath='{.spec.type}')" = ClusterIP
check "DNS has the fixed cluster address $DNS_IP" \
  test "$(kubectl get svc -n "$NS" pihole-dns -o jsonpath='{.spec.clusterIP}')" = "$DNS_IP"
check "DNS has a home network address ($LAN)" test -n "$LAN"
check "password secret exists" kubectl get secret -n "$NS" pihole-web

check "API refuses access without login" test "$(http_code GET /api/stats/summary)" = 401
check "API refuses a wrong password" \
  test "$(http_code POST /api/auth '{"password":"wrongpassword"}')" = 401
check "API works with login" api GET /api/info/version
check "Pi-hole version is 2026.10.1" contains "$(api GET /api/info/version)" '"2026.10.1"'

# Blocklists downloaded (the default list has well over 1000 domains)
BLOCKED="$(api GET /api/stats/summary | grep -o '"domains_being_blocked":[0-9]*' | cut -d: -f2)"
check "blocklists loaded (${BLOCKED:-0} domains)" test "${BLOCKED:-0}" -gt 1000

check "answers DNS inside the cluster ($DNS_IP)" resolves example.com "$DNS_IP"
check "answers DNS on the home network ($LAN)"   resolves example.com "$LAN"
PI_IP="$(kubectl get configmap -n "$NS" home-network -o jsonpath='{.data.pi-ip}')"
check "local name nextcloud.home.arpa -> the Pi" \
  contains "$(lookup nextcloud.home.arpa)" "Address: $PI_IP"
check "the Pi's address matches the DNS service" test "$PI_IP" = "$LAN"
check "pods in the cluster resolve local names too" \
  contains "$(kubectl exec -n "$TEST_NS" "$CLIENT" -- nslookup nextcloud.home.arpa 2>&1)" "Address: $PI_IP"

# Memory: below 80% of the 256Mi limit
MEM="$(kubectl top pod -n "$NS" "$POD" --no-headers 2>/dev/null | awk '{print $3}' | tr -d 'Mi')"
if [[ -z "$MEM" ]]; then warn "memory usage unknown (metrics not ready yet)"
elif [[ "$MEM" -lt 204 ]]; then pass "memory usage ${MEM}Mi (< 80% of limit)"
else fail "memory usage ${MEM}Mi (>= 80% of 256Mi limit)"; fi

finish
