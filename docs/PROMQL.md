# PromQL, with the queries this project uses

Prometheus stores **time series**: a metric name plus labels, with a value per timestamp. PromQL is the language that
selects series and computes on them. The queries below are the real ones, from the alerts
(`helm/posts-api/templates/prometheusrule.yaml`) and the dashboard (`helm/posts-api/dashboards/posts-api.json`).

## The four building blocks

| Piece | Meaning | Example |
|---|---|---|
| Metric types | **Counter** only goes up (requests, restarts); **gauge** goes up and down (replicas, memory); **histogram** counts observations in buckets (durations) | `http_requests_total` is a counter |
| Selector | Pick series by label; `=` equal, `!=` different, `=~` regular expression | `{status_code=~"5.."}` is every 5xx |
| `rate(x[5m])` | Per-second average increase of a counter over the last 5 minutes (survives restarts, which reset counters) | requests per second |
| `sum by (label)` | Add series together, keeping the listed labels | `sum by (route) (...)` is one line per route |

A counter on its own is useless to read (it only says "how many since the pod started"); `rate` or `increase`
turn it into something meaningful.

## The queries

**Requests per second, per route and status** (dashboard):

```promql
sum by (route, status_code) (rate(http_requests_total{namespace="posts"}[5m]))
```

**Error ratio**: 5xx divided by all requests. Used by the alert `PostsApiHighErrorRate` (`> 0.05` for 5 minutes):

```promql
sum(rate(http_requests_total{namespace="posts", status_code=~"5.."}[5m]))
  / sum(rate(http_requests_total{namespace="posts"}[5m]))
```

A 4xx is the client's mistake (401 without a token, 400 for a bad body), so only 5xx counts as the API failing.

**Latency percentile** (alert `PostsApiSlowRequests`: p95 above 1 s for 10 minutes; the dashboard also draws p50 and p99):

```promql
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="posts"}[5m])))
```

The histogram keeps counters per bucket (`le` is "less than or equal"); `histogram_quantile` estimates the percentile
from them. Keep `le` in the `sum by`, or the function has nothing to work with. The estimate is only as precise as the
buckets (5 ms to 5 s in this project).

**Replicas available against wanted** (alerts `PostsApiNoReplicasAvailable` and `PostsApiReplicasUnavailable`,
metrics from kube-state-metrics):

```promql
kube_deployment_status_replicas_available{namespace="posts", deployment="posts-api"} == 0
kube_deployment_status_replicas_available{namespace="posts", deployment="posts-api"}
  < kube_deployment_spec_replicas{namespace="posts", deployment="posts-api"}
```

A comparison filters: the alert fires only for the series where it is true. The second one waits 5 minutes (`for: 5m`)
because a drained node leaves a pod `Pending` for a short while.

**Restarts** (alert `PostsApiPodRestarting`): `increase` is the total growth over a window, not a per-second rate:

```promql
increase(kube_pod_container_status_restarts_total{namespace="posts", pod=~"posts-api-.*"}[15m]) > 3
```

**Memory per pod** and **event loop lag** (dashboard):

```promql
sum by (pod) (container_memory_working_set_bytes{namespace="posts", pod=~"posts-api-.*", container!=""})
nodejs_eventloop_lag_p99_seconds{namespace="posts"}
```

## Common mistakes

- `rate` of a gauge, or a plain counter without `rate`: both give numbers that mean nothing.
- A window shorter than about four scrape intervals (the scrape is every 30 s here): `rate(...[30s])` is empty or noisy.
- An alert without `for`: one bad scrape pages somebody.
- A label with unbounded values (the raw URL, a user id): one series each, and memory grows without limit. That is why
  the route label is the pattern `/posts/:id`.

## Trying a query without a browser

```bash
kubectl --context kind-posts -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &
curl -s 'http://127.0.0.1:19090/api/v1/query' \
  --data-urlencode 'query=sum by (route, status_code) (rate(http_requests_total[5m]))'
```

The rates read 0 when there has been no traffic in the last 5 minutes; send some requests first.
