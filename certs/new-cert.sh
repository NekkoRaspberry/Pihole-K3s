#!/usr/bin/env bash
# Create (or renew) the HTTPS certificate for the home sites (*.home.arpa).
# 1. A private certificate authority (CA), created once. It can ONLY sign *.home.arpa names
#    (name constraint), so even if its key leaked it could not fake any other website.
# 2. A certificate for the sites below, signed by the CA, valid ~2 years.
# 3. Saved as Secret "home-arpa-tls"; Traefik uses it for every *.home.arpa site.
# Install certs/data/ca.crt once on each device (see README). ca.key never leaves the Pi.
# Usage: ./certs/new-cert.sh
set -euo pipefail
# Use ~/.kube/config on the Pi
if [[ -z "${KUBECONFIG:-}" && -f "$HOME/.kube/config" ]]; then export KUBECONFIG="$HOME/.kube/config"; fi

# Sites covered by the certificate (add new ones here and run the script again)
SITES=(nextcloud mailpit pihole)

DIR="$(cd "$(dirname "$0")" && pwd)/data"
mkdir -p "$DIR"
chmod 700 "$DIR"
umask 077   # keys readable only by you
cd "$DIR"

# 1. The CA, created only once (devices trust it, so keep the same one)
if [[ ! -f ca.key ]]; then
  openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout ca.key -out ca.crt -days 3650 -subj "/CN=NekkoRaspberry home CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "nameConstraints=critical,permitted;DNS:home.arpa,excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0" \
    2>/dev/null
  chmod 644 ca.crt   # public part, safe to copy to devices
  echo "Created a new CA: install certs/data/ca.crt on your devices."
fi

# 2. The sites' certificate (800 days: the longest Apple devices accept)
SAN="$(printf 'DNS:%s.home.arpa,' "${SITES[@]}")"
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout site.key -out site.csr -subj "/CN=${SITES[0]}.home.arpa" 2>/dev/null
openssl x509 -req -in site.csr -CA ca.crt -CAkey ca.key -set_serial "0x$(openssl rand -hex 16)" \
  -days 800 -out site.crt 2>/dev/null -extfile <(printf '%s\n' \
    "subjectAltName=${SAN%,}" \
    "basicConstraints=critical,CA:FALSE" \
    "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth")
rm -f site.csr
openssl verify -CAfile ca.crt site.crt >/dev/null

# 3. Give it to Traefik (applied at once, no restart)
kubectl create secret tls home-arpa-tls -n dns --cert=site.crt --key=site.key \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "Done: certificate for ${SAN%,}, valid until $(openssl x509 -in site.crt -noout -enddate | cut -d= -f2)."
