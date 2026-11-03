# Pihole-K3s

One Pi-hole on K3s that answers DNS for the whole home network and blocks ad and tracker domains. Devices use it by pointing their DNS at the Pi.

## Overview

| Item | Value |
|---|---|
| Namespace | `dns` |
| Image | `pihole/pihole:2026.10.1` |
| DNS (home network) | `<PI_IP>:53` (UDP + TCP) |
| DNS (inside the cluster) | `10.43.0.53:53` (fixed, used by WireGuard clients) |
| Web UI + API (inside the cluster) | `pihole-web.dns.svc.cluster.local:80` |
| Web UI (home network) | `https://pihole.home.arpa/admin` (Traefik) |
| Exposure | DNS and web UI on the home network, never the internet |
| Storage | 1 Gi, `local-path`, query history kept 7 days |
| Memory limit | 256 Mi |
| Upstream DNS | `1.1.1.1`, `9.9.9.9` |
| Local names | `nextcloud`, `mailpit`, `pihole` `.home.arpa` → `<PI_IP>` (also for pods: ConfigMap `coredns-custom` sends `*.home.arpa` to Pi-hole) |
| Web UI login | Secret `pihole-web` |
| Pi's address | ConfigMap `home-network` (created at install, not in git) |

> `<PI_IP>` is the Pi's address on your home network (`hostname -I`, first value).

## Files

| File | Purpose |
|---|---|
| `pihole.yaml` | Namespace, services, storage, Pi-hole and the HTTPS certificate setting |
| `certs/new-cert.sh` | Creates the home CA and the HTTPS certificate for `*.home.arpa` |
| `tests/` | Tests, run on the Pi |
| `.github/workflows/tests.yml` | Checks scripts and manifest on push to `main` and `dev` |

## Install

```bash
export KUBECONFIG=~/.kube/config
kubectl create namespace dns
# The Pi's address, kept on the Pi only (used for nextcloud.home.arpa)
kubectl create configmap home-network -n dns --from-literal=pi-ip="$(hostname -I | cut -d' ' -f1)"
kubectl create secret generic pihole-web -n dns \
  --from-literal=password="$(openssl rand -hex 16)"
./certs/new-cert.sh                                               # HTTPS certificate for *.home.arpa
kubectl apply -f pihole.yaml
kubectl rollout status deployment/pihole -n dns --timeout=300s   # first start downloads the blocklists
./tests/run-all.sh
```

## Use it on the home network

1. Give the Pi a fixed address in the router (DHCP reservation for `<PI_IP>`). Everything here depends on it.
2. Try it on **one device** first: set its DNS to `<PI_IP>`, open a few websites.
3. Then set the router's DHCP DNS server to `<PI_IP>`. Devices pick it up when they reconnect.

If the Pi is off, devices using it cannot resolve names. To undo, set the router's DNS back to automatic.

## Web UI

Open https://pihole.home.arpa/admin from any device at home that uses Pi-hole for DNS. Block or allow domains, add blocklists and see queries there.

Password:
```bash
kubectl get secret -n dns pihole-web -o jsonpath='{.data.password}' | base64 -d; echo
```

## HTTPS certificate (home CA)

All `*.home.arpa` sites (Nextcloud, Mailpit, Pi-hole) use one certificate signed by a private **home CA**. Install the CA once on each device and the browser, the Nextcloud app and the desktop client trust them, with no warnings.

The CA can **only** sign `*.home.arpa` names: even if its key leaked, it could not be used to fake any other website.

| File (`certs/data/`, never in git) | What it is |
|---|---|
| `ca.crt` | Public CA certificate: copy this to your devices |
| `ca.key` | CA private key: **never leaves the Pi** |
| `site.crt`, `site.key` | The sites' certificate (also in Secret `home-arpa-tls`) |

Install `ca.crt` on a device (in VS Code: right-click `certs/data/ca.crt` → Download):
- **Windows:** double-click → Install Certificate → Local Machine → "Place all certificates in the following store" → **Trusted Root Certification Authorities**. Restart the browser.
- **Android:** Settings → Security → Encryption & credentials → Install a certificate → **CA certificate**.
- **iPhone:** open the file → install the profile in Settings → then General → About → **Certificate Trust Settings** → turn it on.

Renew (valid 800 days; `01-running.sh` fails 30 days before it expires) or add a new site (edit `SITES` in the script):
```bash
./certs/new-cert.sh    # keeps the same CA, devices need nothing new
```

If `ca.key` is lost, run the script again: it creates a new CA, which must be installed on every device again. Keep a copy of `certs/data/` somewhere safe (e.g. a password manager).

## Useful commands

```bash
kubectl get pods,pvc,svc -n dns                          # status
kubectl logs -n dns deploy/pihole --tail=50              # logs
kubectl exec -n dns deploy/pihole -- pihole deny -l      # extra blocked domains
kubectl exec -n dns deploy/pihole -- pihole -g           # update the blocklists now
```

## Tests

Run on the Pi:
```bash
./tests/run-all.sh
```

| Test | Checks |
|---|---|
| `01-running.sh` | Pod, storage, services, login required, version, blocklists, DNS on both addresses, local names, HTTPS certificate trusted and not expiring, CA limited to `home.arpa`, memory |
| `02-blocking.sh` | A blocked domain gets 0.0.0.0 on both addresses, unblocking undoes it |
| `03-deploying.sh` | Manifest valid, no drift, blocked domains and password survive a restart |
| `99-leftovers.sh` | Nothing left behind by the tests |

Test domains (`dnstest*.example.com`) are removed at the end. The helper pod uses the temporary namespace `dnstest`, deleted at the end. `03` restarts Pi-hole once (DNS pauses for a few seconds).

On push, `.github/workflows/tests.yml` checks script syntax (shellcheck) and the manifest (kubeconform) on `ubuntu-latest` (it also works on `nekko-runners`). It has no access to the cluster.

## Notes

- The web UI is never exposed outside the cluster.
- Do not change the fixed address `10.43.0.53`: WireGuard clients use it as their DNS.
- Settings in `pihole.yaml` (`FTLCONF_*`) are read-only in the web UI. Change them in the file and apply it.
