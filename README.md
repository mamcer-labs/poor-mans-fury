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
| Logs | Loki + Promtail |
| Traces | Tempo + OpenTelemetry |
| Catalog & scaffolding | Backstage |
| Day-to-day operations | `pmf`, a small CLI (below) |

Apps are deployed per **scope** into their own namespaces: `fury-dev`,
`fury-staging`, `fury-prod`. Platform components live in `fury-infra`.

## Repository layout

```
cli/pmf.sh                   pmf CLI: deploy, logs, status, rollback, scope list, config get
deploy/dev/                  Kubernetes manifests for the apps running in fury-dev
  gostalgia-api.yaml           Go API: Deployment + Service, config injected from Vault
  cookbook.yaml                second app, with a ServiceMonitor for Prometheus
observability/
  prometheus-values.yaml       Helm values for kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
  loki-values.yaml             Helm values for Loki (single binary, filesystem storage)
traefik/values.yaml          Helm values for Traefik
vault/
  values.yaml                  Helm values for Vault (standalone, UI enabled)
  ingress.yaml                 Traefik IngressRoute for the Vault UI
  policies/gostalgia-dev.hcl   read-only policy for gostalgia's dev config
```

Not every component has its configuration here yet; some were installed
directly with Helm while building the platform (see the write-up below).

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
