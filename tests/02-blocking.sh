#!/usr/bin/env bash
# Does blocking work on both addresses, and does unblocking undo it?
# Adds temporary test domains to the deny list and removes them at the end.
source "$(dirname "$0")/lib.sh"
echo "== 02 Blocking"

A=dnstesta.example.com
B=dnstestb.example.com

cleanup() {
  for D in "$A" "$B"; do
    is_denied "$D" && deny_remove "$D" >/dev/null 2>&1
  done
}
trap 'cleanup; client_stop' EXIT
client_start
cleanup   # start from a clean state
LAN="$(lan_ip)"

check_fails "A is not blocked before"     is_blocked "$A"
check "adds A to the deny list"           deny_add "$A"
check "adds B to the deny list"           deny_add "$B"
sleep 2   # Pi-hole applies list changes within a second

check "A is blocked inside the cluster"   is_blocked "$A" "$DNS_IP"
check "A is blocked on the home network"  is_blocked "$A" "$LAN"
check "B is blocked"                      is_blocked "$B"
check "normal domains still work"         resolves example.com

check "removes B from the deny list"      deny_remove "$B"
sleep 2
check_fails "B is no longer blocked"      is_blocked "$B"
check_fails "B is no longer on the list"  is_denied "$B"
check "A stays blocked"                   is_blocked "$A"

finish
