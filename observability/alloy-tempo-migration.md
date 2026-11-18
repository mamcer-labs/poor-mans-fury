# Promtail → Alloy, and Tempo to the community chart

Status: **planned, not applied** (18/11/2026). Manifests are ready in this
folder; the steps below are the cutover.

## Why

| Component | Today | Problem | Replacement |
|---|---|---|---|
| Log collector | `grafana/promtail` 6.17.1 (Promtail 3.5.1) | Promtail reached **EOL on 02/03/2026**; the chart is marked `deprecated: true` | `grafana/alloy` 1.16.0 (Alloy v1.22.0), DaemonSet |
| Traces | `grafana/tempo` 1.24.4 (Tempo 2.9.0) | Chart marked `deprecated: true`: it **moved** to `grafana-community/helm-charts` (no updates in `grafana/` after 30/01/2026). It was not replaced by another product | `grafana-community/tempo` 3.2.1 (Tempo 3.1.1), same single-binary mode |
| Logs store | `grafana/loki` 7.1.0 (Loki 3.6.8) | Same story, found while checking: since 16/03/2026 the OSS chart lives in `grafana-community` (21.3.1, Loki 3.7.10); `grafana/loki` is kept for Enterprise only | Out of scope here; next item |

### Found on the way: Promtail never shipped a log (fixed 18/11)

Promtail answered every push with `401 Unauthorized: no org id` and Loki
had no streams at all for the last 29 days (the query limit). Loki runs with
`auth_enabled: true`, and the July install flags (`config.lokiAddress`,
`config.snippets.extraClientConfigs=tenant_id: ...`) are ignored by Promtail
chart 6.x, which reads the client from `config.clients`. Fixed with
`promtail-values.yaml` (`helm upgrade`, revision 2); streams showed up for
every namespace within a minute. `alloy-values.yaml` sets `tenant_id` in
`loki.write` for the same reason.

## 1. Promtail → Alloy

`alloy-values.yaml` reproduces the Promtail chart's `kubernetes-pods` job:
pod discovery, the same relabel rules, tailing `/var/log/pods` (not
`loki.source.kubernetes`, which streams logs through the API server) and the
CRI parser. Streams keep the same labels, so `{namespace="fury-dev"} |=
"<trace_id>"` and the "Logs for this span" link keep working. The config was
checked with `alloy fmt` (v1.22.0) and the chart renders with `helm template`.

Cutover (a gap of a few seconds in logs is acceptable here):

```bash
helm repo update grafana
helm upgrade --install alloy grafana/alloy --version 1.16.0 \
  -n fury-monitoring -f observability/alloy-values.yaml
kubectl -n fury-monitoring rollout status ds/alloy

# Both running for a minute is fine: Alloy starts at the end of each file
# (tail_from_end), so the overlap is a handful of duplicated lines at most.
helm uninstall promtail -n fury-monitoring
git rm observability/promtail-values.yaml
```

Check:

```bash
kubectl -n fury-monitoring logs ds/alloy | grep -iE "level=(error|warn)"
kubectl -n fury-monitoring port-forward svc/loki-gateway 31000:80 &
curl -s -H "X-Scope-OrgID: poor-mans-fury" localhost:31000/loki/api/v1/labels
# same labels as before: app component container filename instance job
# namespace node_name pod service_name stream
curl -s http://localhost:8080/v1/debug/fail   # via port-forward to gostalgia-api
# then Grafana: Tempo trace → "Logs for this span" must land on the log line
```

Rollback: `helm uninstall alloy` and `helm upgrade --install promtail
grafana/promtail --version 6.17.1 -f observability/promtail-values.yaml`.

Later, optional: Alloy can also receive OTLP and forward traces to Tempo
(one collector for logs and traces). Not needed today: the apps send straight
to `tempo.fury-monitoring.svc.cluster.local:4317`.

## 2. Tempo 2.9 → 3.1 (community chart)

Tempo 3.0 drops the ingester write path. In microservices mode it now needs
Kafka, but **single binary doesn't**, and that's what this chart runs. What
matters for us:

- `tempo-values.yaml` uses only `tempo.storage.trace.backend: local` and
  `persistence`, which the 3.x chart keeps with the same names. None of the
  removed values (`tempo.ingester`, `memBallastSizeMbs`,
  `metricsGenerator.traces_storage`) are set.
- Same resource names: StatefulSet `tempo`, PVC `storage-tempo-0`, Service
  `tempo` with OTLP on 4317/4318 and HTTP on 3200. Apps and the Grafana
  datasource don't change.
- Retention stays at 24 h (the default in both charts). Chart 3.2.0 fixed
  retention being silently 14 days in 3.0-3.1; we skip those versions.
- **No downgrade from 3.x to 2.x.** With 24 h of demo traces, the rollback is
  "delete the PVC and reinstall 1.24.4", not a data migration.

```bash
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update grafana-community
helm diff upgrade tempo grafana-community/tempo --version 3.2.1 \
  -n fury-monitoring -f observability/tempo-values.yaml   # if helm-diff is installed
helm upgrade tempo grafana-community/tempo --version 3.2.1 \
  -n fury-monitoring -f observability/tempo-values.yaml
kubectl -n fury-monitoring rollout status sts/tempo
```

If the upgrade fails with `spec: Forbidden: updates to statefulset spec`
(the chart changed something immutable, like the `volumeClaimTemplates`
labels), recreate the StatefulSet keeping the pod and the PVC:

```bash
kubectl -n fury-monitoring delete sts tempo --cascade=orphan
helm upgrade tempo grafana-community/tempo --version 3.2.1 \
  -n fury-monitoring -f observability/tempo-values.yaml
```

Check: `kubectl -n fury-monitoring logs tempo-0 | grep -i error`, hit
`/v1/debug/fail` on gostalgia-api, and find the trace in Grafana → Explore →
Tempo. Then "Logs for this span" (needs step 1's logs).

## Order

1. Alloy (independent, and it is what makes trace ↔ logs work end to end).
2. Tempo, a day later, so a problem in one isn't confused with the other.
3. Loki to `grafana-community/loki`: separate plan. The fork started at chart
   6.55.0 and we run 7.1.0 from the Enterprise line, so it needs reading
   before touching it.

## Sources

- Alloy, migrate from Promtail: <https://grafana.com/docs/alloy/latest/set-up/migrate/from-promtail/> (Promtail EOL 02/03/2026)
- Tempo 3.0 release notes and upgrade: <https://grafana.com/docs/tempo/latest/release-notes/v3-0/>, <https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/upgrade/>
- `helm show readme grafana/tempo --version 1.24.4` (chart migration notice), `helm show readme grafana-community/tempo --version 3.2.1` (upgrading section), `helm show readme grafana/loki --version 7.6.0`
- grafana-community chart index: <https://grafana-community.github.io/helm-charts/index.yaml> (checked 18/11/2026)
