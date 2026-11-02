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
| Exposure | DNS on the home network, web UI ClusterIP only |
| Storage | 1 Gi, `local-path`, query history kept 7 days |
| Memory limit | 256 Mi |
| Upstream DNS | `1.1.1.1`, `9.9.9.9` |
| Local names | `nextcloud.home.arpa` → `<PI_IP>` |
| Web UI login | Secret `pihole-web` |

## Files

| File | Purpose |
|---|---|
| `pihole.yaml` | Namespace, services, storage and Pi-hole |
| `tests/` | Tests, run on the Pi |
| `.github/workflows/tests.yml` | Checks scripts and manifest on push to `main` and `dev` |

## Install

```bash
export KUBECONFIG=~/.kube/config
kubectl create namespace dns
kubectl create secret generic pihole-web -n dns \
  --from-literal=password="$(openssl rand -hex 16)"
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

```bash
kubectl port-forward -n dns svc/pihole-web 8080:80
```
Open http://localhost:8080/admin (VS Code forwards the port automatically). Block or allow domains, add blocklists and see queries there.

Password:
```bash
kubectl get secret -n dns pihole-web -o jsonpath='{.data.password}' | base64 -d; echo
```

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
| `01-running.sh` | Pod, storage, services, login required, version, blocklists, DNS on both addresses, local names, memory |
| `02-blocking.sh` | A blocked domain gets 0.0.0.0 on both addresses, unblocking undoes it |
| `03-deploying.sh` | Manifest valid, no drift, blocked domains and password survive a restart |
| `99-leftovers.sh` | Nothing left behind by the tests |

Test domains (`dnstest*.example.com`) are removed at the end. The helper pod uses the temporary namespace `dnstest`, deleted at the end. `03` restarts Pi-hole once (DNS pauses for a few seconds).

On push, `.github/workflows/tests.yml` checks script syntax (shellcheck) and the manifest (kubeconform) on `ubuntu-latest` (it also works on `nekko-runners`). It has no access to the cluster.

## Notes

- The web UI is never exposed outside the cluster.
- Do not change the fixed address `10.43.0.53`: WireGuard clients use it as their DNS.
- Settings in `pihole.yaml` (`FTLCONF_*`) are read-only in the web UI. Change them in the file and apply it.
