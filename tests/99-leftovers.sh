#!/usr/bin/env bash
# Did the tests clean up after themselves? (run last)
source "$(dirname "$0")/lib.sh"
echo "== 99 Leftovers"

check_fails "no test domains on the deny list" is_denied 'dnstest[a-z]*\.example\.com'

trap client_stop EXIT
client_start
for D in dnstesta.example.com dnstestb.example.com dnstestp.example.com; do
  check_fails "test domain not blocked ($D)" is_blocked "$D"
done

finish
