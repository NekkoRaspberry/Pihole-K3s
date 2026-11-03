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
check "web UI service is internal only (ClusterIP)" \
  test "$(kubectl get svc -n "$NS" pihole-web -o jsonpath='{.spec.type}')" = ClusterIP
check "home network address is pihole.home.arpa" \
  test "$(kubectl get ingress -n "$NS" pihole -o jsonpath='{.spec.rules[0].host}')" = pihole.home.arpa
check "DNS has the fixed cluster address $DNS_IP" \
  test "$(kubectl get svc -n "$NS" pihole-dns -o jsonpath='{.spec.clusterIP}')" = "$DNS_IP"
check "DNS has a home network address ($LAN)" test -n "$LAN"
check "password secret exists" kubectl get secret -n "$NS" pihole-web

check "API refuses access without login" test "$(http_code GET /api/stats/summary)" = 401
check "API over HTTPS on the home network refuses access without login" test "$(kubectl exec -n "$TEST_NS" "$CLIENT" -- \
  curl -sk -o /dev/null -w '%{http_code}' --resolve "pihole.home.arpa:443:$LAN" https://pihole.home.arpa/api/stats/summary)" = 401
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
for NAME in nextcloud mailpit pihole; do
  check "local name $NAME.home.arpa -> the Pi" contains "$(lookup "$NAME.home.arpa")" "Address: $PI_IP"
done
check "the Pi's address matches the DNS service" test "$PI_IP" = "$LAN"
check "pods in the cluster resolve local names too" \
  contains "$(kubectl exec -n "$TEST_NS" "$CLIENT" -- nslookup nextcloud.home.arpa 2>&1)" "Address: $PI_IP"

# HTTPS: every *.home.arpa site uses the home CA's certificate (checked like a device that installed it)
check "certificate secret exists" kubectl get secret -n "$NS" home-arpa-tls
for NAME in nextcloud mailpit pihole; do
  check "https://$NAME.home.arpa is trusted with the home CA" sh -c "kubectl exec -i -n $TEST_NS $CLIENT -- \
    sh -c 'cat > /tmp/ca.crt && curl -s -o /dev/null --cacert /tmp/ca.crt --resolve $NAME.home.arpa:443:$LAN https://$NAME.home.arpa/' < '$CA'"
done
CERT="$(kubectl get secret -n "$NS" home-arpa-tls -o jsonpath='{.data.tls\.crt}' | base64 -d)"
if openssl x509 -noout -checkend 2592000 <<< "$CERT" >/dev/null; then
  pass "certificate valid for 30+ days (until $(openssl x509 -noout -enddate <<< "$CERT" | cut -d= -f2))"
else fail "certificate expires within 30 days: run ./certs/new-cert.sh"; fi

# The CA must refuse any name outside home.arpa (so a leaked key cannot fake other sites)
TMP="$(mktemp -d)"
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$TMP/k" -out "$TMP/csr" \
  -subj /CN=example.com >/dev/null 2>&1
openssl x509 -req -in "$TMP/csr" -CA "$CA" -CAkey "$ROOT/certs/data/ca.key" -set_serial 1 -days 1 -out "$TMP/crt" \
  -extfile <(echo subjectAltName=DNS:example.com) >/dev/null 2>&1
check_fails "home CA cannot be used for other websites" openssl verify -CAfile "$CA" "$TMP/crt"
rm -rf "$TMP"

# Memory: below 80% of the 256Mi limit
MEM="$(kubectl top pod -n "$NS" "$POD" --no-headers 2>/dev/null | awk '{print $3}' | tr -d 'Mi')"
if [[ -z "$MEM" ]]; then warn "memory usage unknown (metrics not ready yet)"
elif [[ "$MEM" -lt 204 ]]; then pass "memory usage ${MEM}Mi (< 80% of limit)"
else fail "memory usage ${MEM}Mi (>= 80% of 256Mi limit)"; fi

finish
