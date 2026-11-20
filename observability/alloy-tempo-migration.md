# Promtail → Alloy, and Tempo to the community chart

Status: **applied 20/11/2026**. Loki to `grafana-community/loki` is still
pending (see the end).

| Component | Before | Now | Why |
|---|---|---|---|
| Log collector | `grafana/promtail` 6.17.1 (Promtail 3.5.1) | `grafana/alloy` 1.16.0 (Alloy v1.22.0), DaemonSet | Promtail reached **EOL on 02/03/2026**; chart marked `deprecated: true` |
| Traces | `grafana/tempo` 1.24.4 (Tempo 2.9.0) | `grafana-community/tempo` 3.2.1 (Tempo 3.1.1), single binary | The chart **moved** to `grafana-community/helm-charts`; no updates in `grafana/` after 30/01/2026 |
| Logs store | `grafana/loki` 7.1.0 (Loki 3.6.8) | unchanged | Since 16/03/2026 the OSS chart lives in `grafana-community` (21.3.1, Loki 3.7.10); `grafana/loki` is Enterprise only |

### Before this: Promtail never shipped a log (fixed 18/11)

Promtail answered every push with `401 Unauthorized: no org id`. Loki runs
with `auth_enabled: true`, and the July install flags (`config.lokiAddress`,
`config.snippets.extraClientConfigs`) are ignored by Promtail chart 6.x, which
reads the client from `config.clients`. Fixed on 18/11 with a values file;
Alloy sets `tenant_id` in `loki.write` for the same reason.

## 1. Promtail → Alloy

`alloy-values.yaml` reproduces the Promtail chart's `kubernetes-pods` job:
pod discovery, the same relabel rules, tailing `/var/log/pods` (not
`loki.source.kubernetes`, which streams logs through the API server) and the
CRI parser. Streams keep the same labels, so `{namespace="fury-dev"} |=
"<trace_id>"` and the "Logs for this span" link keep working.

```bash
helm repo update grafana
helm upgrade --install alloy grafana/alloy --version 1.16.0 \
  -n fury-monitoring -f observability/alloy-values.yaml
kubectl -n fury-monitoring rollout status ds/alloy
# no errors or warnings in its logs → remove Promtail
helm uninstall promtail -n fury-monitoring
```

`tail_from_end = true` matters: Alloy doesn't read Promtail's positions file,
and without it the first start re-sends every log still on disk.

Verified after removing Promtail: `GET /v1/debug/fail` on gostalgia-api, and
the error line (with its `trace_id`) was in Loki within seconds, under the
same 11 labels as before (`app component container filename instance job
namespace node_name pod service_name stream`).

Rollback (needs the values from git history, `git show a56a99c:observability/promtail-values.yaml`):

```bash
helm uninstall alloy -n fury-monitoring
helm upgrade --install promtail grafana/promtail --version 6.17.1 \
  -n fury-monitoring -f promtail-values.yaml
```

Later, optional: Alloy can also receive OTLP and forward traces to Tempo.
Not needed today: the apps send straight to
`tempo.fury-monitoring.svc.cluster.local:4317`.

## 2. Tempo 2.9 → 3.1 (community chart)

Tempo 3.0 drops the ingester write path; microservices mode now needs Kafka,
but **single binary doesn't**. `tempo-values.yaml` only sets
`tempo.storage.trace.backend: local` and `persistence`, which 3.x keeps.

Before upgrading, `helm template` of the new chart was compared with the live
manifest: same StatefulSet `serviceName`, `selector` and
`volumeClaimTemplates` (the immutable fields), same Service ports
(4317/4318/3200), retention 24 h. The new chart only adds a `tempo-headless`
Service. So a plain upgrade, keeping the PVC `storage-tempo-0`:

```bash
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm upgrade tempo grafana-community/tempo --version 3.2.1 \
  -n fury-monitoring -f observability/tempo-values.yaml
kubectl -n fury-monitoring rollout status sts/tempo
```

Verified: a new `/v1/debug/fail` trace was found in Tempo by the `trace_id`
from its Loki log line (`/api/v2/traces/<id>`), and TraceQL search
(`{resource.service.name="gostalgia-api"}`) returns traces from before and
after the upgrade.

Expected noise in the logs, not errors: `Scheduler address is empty in single
binary mode` (it configures itself) and `error calling scheduler ... no jobs
found` (the backend worker polling when there is nothing to compact).

**No downgrade from 3.x to 2.x.** With 24 h of demo traces, the rollback is
deleting the PVC and reinstalling `grafana/tempo` 1.24.4.

## 3. Next: Loki to `grafana-community/loki`

Separate plan. The fork started at chart 6.55.0 and we run 7.1.0 from the
Enterprise line, so it needs reading before touching it.

## Sources

- Alloy, migrate from Promtail: <https://grafana.com/docs/alloy/latest/set-up/migrate/from-promtail/> (Promtail EOL 02/03/2026)
- Tempo 3.0 release notes and upgrade: <https://grafana.com/docs/tempo/latest/release-notes/v3-0/>, <https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/upgrade/>
- `helm show readme grafana/tempo --version 1.24.4` (chart migration notice), `helm show readme grafana-community/tempo --version 3.2.1` (upgrading section), `helm show readme grafana/loki --version 7.6.0`
- grafana-community chart index: <https://grafana-community.github.io/helm-charts/index.yaml> (checked 18/11/2026)
