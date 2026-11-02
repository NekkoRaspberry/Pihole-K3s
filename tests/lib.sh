# shellcheck shell=bash
# Shared helpers for the tests (loaded by each test file, not run directly)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=dns
TEST_NS=dnstest          # temporary namespace for the helper pod (deleted by run-all.sh)
CLIENT=dnstest-client    # helper pod with curl and nslookup, acts like a device
WEB=pihole-web.dns.svc.cluster.local
DNS_IP=10.43.0.53        # fixed cluster address of the DNS service
FAILS=0

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); }
warn() { echo "  WARN  $1"; }

# check "<description>" <command...>  -> PASS if the command succeeds
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

# check_fails "<description>" <command...>  -> PASS if the command FAILS
check_fails() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi
}

# contains "<text>" "<part>"  -> succeeds if text contains part
contains() { grep -qF -- "$2" <<< "$1"; }

# Name of the running Pi-hole pod (it changes after every restart)
pihole_pod() { kubectl get pod -n "$NS" -l app=pihole -o jsonpath='{.items[0].metadata.name}'; }

# Address of Pi-hole on the home network (the Pi's address)
lan_ip() { kubectl get svc -n "$NS" pihole-dns -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; }

# Helper pod that asks Pi-hole like a device would
client_start() {
  kubectl create namespace "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl run "$CLIENT" -n "$TEST_NS" --restart=Never --image=curlimages/curl:8.22.0 \
    --command -- sleep 600 >/dev/null
  kubectl wait -n "$TEST_NS" --for=condition=Ready "pod/$CLIENT" --timeout=90s >/dev/null
}
client_stop() { kubectl delete pod -n "$TEST_NS" "$CLIENT" --ignore-not-found --grace-period=1 >/dev/null 2>&1; }

# Ask a DNS server for a domain. Usage: lookup <domain> [server]  -> prints the answer
lookup() { kubectl exec -n "$TEST_NS" "$CLIENT" -- nslookup "$1" "${2:-$DNS_IP}" 2>&1; }

# Is the domain blocked (answer 0.0.0.0)? Usage: is_blocked <domain> [server]
is_blocked() { contains "$(lookup "$@")" "Address: 0.0.0.0"; }

# Does the domain get a real answer? Usage: resolves <domain> [server]
resolves() {
  local out
  out="$(lookup "$@")"
  contains "$out" "Name:" && ! contains "$out" "Address: 0.0.0.0"
}

# After a restart DNS answers a few seconds after the pod is Ready: wait up to 30s
wait_dns() {
  for _ in $(seq 1 15); do resolves example.com && return 0; sleep 2; done
  return 1
}

# Is the domain on Pi-hole's deny list? (regex allowed, e.g. "dnstest[a-z]*")
is_denied() { kubectl exec -n "$NS" deploy/pihole -- pihole deny -l | grep -q "\"$1\""; }

# Add / remove a domain on the deny list (the same list the web UI edits)
deny_add()    { kubectl exec -n "$NS" deploy/pihole -- pihole deny -q "$1" --comment "pihole tests"; }
deny_remove() { kubectl exec -n "$NS" deploy/pihole -- pihole deny remove -q "$1"; }

# Call the Pi-hole API with the web UI password: log in, call, log out.
# Usage: api <METHOD> <path>
api() {
  local pass
  pass="$(kubectl get secret -n "$NS" pihole-web -o jsonpath='{.data.password}' | base64 -d)"
  kubectl exec -n "$TEST_NS" "$CLIENT" -- sh -c "
    sid=\$(curl -sS --fail -X POST http://$WEB/api/auth -d '{\"password\":\"$pass\"}' |
      grep -o '\"sid\":\"[^\"]*\"' | cut -d'\"' -f4)
    [ -n \"\$sid\" ] || exit 1
    curl -sS --fail -X $1 -H \"X-FTL-SID: \$sid\" http://$WEB$2; rc=\$?
    curl -s -o /dev/null -X DELETE -H \"X-FTL-SID: \$sid\" http://$WEB/api/auth
    exit \$rc"
}

# HTTP status of an API call without a valid login. Usage: http_code <METHOD> <path> [body]
http_code() {
  kubectl exec -n "$TEST_NS" "$CLIENT" -- \
    curl -s -o /dev/null -w '%{http_code}' -X "$1" "http://$WEB$2" ${3:+-d "$3"}
}

# Print the result and exit with 0 (all good) or 1 (something failed)
finish() {
  if [[ "$FAILS" -eq 0 ]]; then echo "  -> all passed"; exit 0
  else echo "  -> $FAILS failed"; exit 1; fi
}
