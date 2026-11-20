# Poor Man's Fury

Infrastructure-as-code for **Poor Man's Fury**: an internal developer platform
built from scratch on a single home server (an Intel NUC), inspired by Fury,
Mercado Libre's internal platform for building and running microservices.

The goal is the same developer experience on a much smaller scale: you write
the service; CI/CD, secrets, observability and the service catalog are handled
by the platform.

## Stack

| Concern | Tool |
|---|---|
| Cluster | K3s on Ubuntu Server |
| Ingress | Traefik |
| Secrets | HashiCorp Vault (standalone, injected into pods by the Vault Agent) |
| CI/CD | GitHub Actions on a self-hosted runner, images in GHCR |
| Metrics & dashboards | Prometheus + Grafana (kube-prometheus-stack) |
| Logs | Loki + Grafana Alloy |
| Traces | Tempo + OpenTelemetry |
| Catalog & scaffolding | Backstage |
| Day-to-day operations | `pmf`, a small CLI (below) |

Apps are deployed per **scope** into their own namespaces: `fury-dev`,
`fury-staging`, `fury-prod`. Platform components live in `fury-infra`.

## Repository layout

```
apparmor/cri-containerd.apparmor.d  host AppArmor profile for containers (see Known issues)
backstage/rbac.yaml          read-only ServiceAccount for Backstage's Kubernetes view
cli/pmf.sh                   pmf CLI: deploy, logs, status, rollback, scope list, config get
deploy/dev/                  Kubernetes manifests for the apps running in fury-dev
  gostalgia-api.yaml           Go API: Deployment + Service, config injected from Vault
  cookbook.yaml                second app, with a ServiceMonitor for Prometheus
media/navidrome.yaml         Navidrome music server (LAN only), outside the Fury scopes
media/immich.yaml            Immich photo and video library (LAN only), outside the Fury scopes
media/sist2.yaml             sist2 full-text search over homunculus/doc (LAN only), outside the Fury scopes
observability/
  prometheus-values.yaml       Helm values for kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
  loki-values.yaml             Helm values for Loki (single binary, filesystem storage)
  tempo-values.yaml            Helm values for Tempo (local trace storage)
  grafana-ingress.yaml         Traefik IngressRoute for Grafana
  gostalgia-servicemonitor.yaml  ServiceMonitor that scrapes gostalgia-api's metrics
  gostalgia-slo-rules.yaml     latency SLO: recording rules + multi-window burn-rate alerts
  dashboards/gostalgia-red.yaml  RED dashboard, loaded by Grafana's dashboard sidecar
traefik/values.yaml          Helm values for Traefik
vault/
  values.yaml                  Helm values for Vault (standalone, UI enabled)
  ingress.yaml                 Traefik IngressRoute for the Vault UI
  policies/                    one read-only policy per app and scope
```

Not every component has its configuration here yet; some were installed
directly with Helm while building the platform (see the write-up below).

## Conventions

- Every manifest applied to the cluster lives in this repo, organized by
  tool (`vault/`, `traefik/`, `observability/`, `deploy/<scope>/`).
- Traefik CRDs use `apiVersion: traefik.io/v1alpha1`.
- Scope namespaces are labeled `fury/scope=<dev|staging|prod>`.
- App config lives in Vault at `fury/apps/<app>/<scope>/config`, readable
  only through the policy `vault/policies/<app>-<scope>.hcl`.
- `ServiceMonitor`s and `PrometheusRule`s carry the label
  `release: monitoring` so the Prometheus operator picks them up.

## Known issues

**Processes in a container can't signal each other (Ubuntu 26.04).**
- Ubuntu sets `kernel.apparmor_restrict_unprivileged_unconfined=1`. Because of
  it, runc's switch into containerd's default AppArmor profile becomes a stack,
  and container processes are labeled `cri-containerd.apparmor.d//&unconfined`.
- The default profile only allows signals and ptrace between processes labeled
  `cri-containerd.apparmor.d`, so the kernel denies them
  (`apparmor="DENIED" operation="signal"`).
- Effects: Postgres can't create a database ("could not signal for
  checkpoint"), `gosu` spins at 100% CPU, and Go programs (Vault, Navidrome)
  lose their SIGURG preemption signals.
- Upstream: [containerd#14485](https://github.com/containerd/containerd/issues/14485),
  [k3s#13625](https://github.com/k3s-io/k3s/issues/13625).

Workaround (temporary): `apparmor/cri-containerd.apparmor.d` is containerd's
profile with the stacked label added to those two rules. containerd keeps a
profile that is already loaded under that name, and `/etc/apparmor.d` is
loaded at boot before k3s. Install it with:

```bash
sudo install -m 0644 apparmor/cri-containerd.apparmor.d /etc/apparmor.d/
sudo apparmor_parser -r -W /etc/apparmor.d/cri-containerd.apparmor.d
```

The reload applies to running containers; no pod restarts. To check it:

```bash
journalctl -k --since "10 min ago" | grep 'apparmor="DENIED" operation="signal"'
```

The output must be empty. Remove the file and reboot when the pinned k3s
ships containerd with the fix
([containerd#14487](https://github.com/containerd/containerd/pull/14487)). If
k3s upgrades containerd before that, diff the file against the new
`contrib/apparmor/template.go`.

## The `pmf` CLI

`pmf` wraps existing `kubectl` and `vault` commands in a small vocabulary:

```
pmf deploy <app> <version> <scope>   deploy an image to a scope
pmf logs <app> <scope> [-f]          tail logs
pmf status <app>                     deployment status across all scopes
pmf rollback <app> <scope>           roll back to the previous revision
pmf scope list <app>                 scopes where the app is deployed
pmf config get <app> <scope>         read the app's config from Vault
```

The CI pipeline of each app calls `pmf deploy` as its last step.

## Not in this repo (on purpose)

- Vault initialization output (unseal keys, root token). It lives only on the
  server, outside any repository.
- Application secrets. They are stored in Vault and injected at runtime.
- Application code. See [gostalgia](https://github.com/mamcer-labs/gostalgia).

## Write-up

The full build log, with the real commands, errors and fixes, is a 5-part
series on my blog (in Spanish):

1. [Cluster, ingress and the first pipeline](https://mamcer.github.io/poor-mans-fury-parte-1/)
2. [Vault and observability](https://mamcer.github.io/poor-mans-fury-parte-2/)
3. [Traces, metrics and error budgets](https://mamcer.github.io/poor-mans-fury-parte-3/)
4. [Catalog and scaffolding](https://mamcer.github.io/poor-mans-fury-parte-4/)
5. [CLI and the full flow](https://mamcer.github.io/poor-mans-fury-parte-5/)

This is a homelab: single node, no high availability, and some deliberate
shortcuts (for example, Vault is unsealed manually after a restart). The
trade-offs are discussed in the series.

## License

[MIT](LICENSE)
