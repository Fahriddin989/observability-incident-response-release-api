#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kubeadm-project4.conf}"

APP_NS="${APP_NS:-release-api-dev}"
APP_LABEL="${APP_LABEL:-app.kubernetes.io/name=release-api}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
ARGOCD_APP="${ARGOCD_APP:-release-api-dev}"
PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="outputs/incidents/${TS}-${ARGOCD_APP}"

mkdir -p "$OUT_DIR/logs" "$OUT_DIR/describes" "$OUT_DIR/prometheus"

run() {
  local name="$1"
  shift
  echo "Collecting: $name"
  {
    echo "# $name"
    echo "# command: $*"
    echo
    "$@"
  } > "${OUT_DIR}/${name}.txt" 2>&1 || true
}

run "cluster-context" kubectl config current-context
run "nodes" kubectl get nodes -o wide
run "app-workloads" kubectl -n "$APP_NS" get deploy,rs,pods,svc,endpoints,endpointslice,configmap,sa -o wide
run "app-events" kubectl -n "$APP_NS" get events --sort-by=.lastTimestamp
run "monitoring-alerts" kubectl -n monitoring get prometheusrule
run "argocd-application" kubectl -n "$ARGOCD_NS" get application "$ARGOCD_APP" -o yaml

kubectl -n "$APP_NS" describe deployment release-api > "${OUT_DIR}/describes/deployment-release-api.txt" 2>&1 || true

for pod in $(kubectl -n "$APP_NS" get pods -l "$APP_LABEL" -o jsonpath='{.items[*].metadata.name}'); do
  echo "Collecting pod context: $pod"

  kubectl -n "$APP_NS" describe pod "$pod" \
    > "${OUT_DIR}/describes/pod-${pod}.txt" 2>&1 || true

  kubectl -n "$APP_NS" logs "$pod" --all-containers=true \
    > "${OUT_DIR}/logs/${pod}-current.log" 2>&1 || true

  kubectl -n "$APP_NS" logs "$pod" --all-containers=true --previous \
    > "${OUT_DIR}/logs/${pod}-previous.log" 2>&1 || true
done

if curl -fsS "${PROM_URL}/-/ready" >/dev/null 2>&1; then
  echo "Collecting Prometheus alerts from ${PROM_URL}"

  curl -s "${PROM_URL}/api/v1/alerts" \
    > "${OUT_DIR}/prometheus/alerts.json" || true

  curl -sG "${PROM_URL}/api/v1/query" \
    --data-urlencode 'query=kube_deployment_status_replicas_available{namespace="release-api-dev",deployment="release-api"}' \
    > "${OUT_DIR}/prometheus/release-api-available-replicas.json" || true

  curl -sG "${PROM_URL}/api/v1/query" \
    --data-urlencode 'query=sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="release-api-dev",container="release-api"}[15m]))' \
    > "${OUT_DIR}/prometheus/release-api-restarts-15m.json" || true

  curl -sG "${PROM_URL}/api/v1/query" \
    --data-urlencode 'query=sum by (method,path,status) (rate(release_api_http_requests_total[5m]))' \
    > "${OUT_DIR}/prometheus/release-api-request-rate.json" || true

  curl -sG "${PROM_URL}/api/v1/query" \
    --data-urlencode 'query=histogram_quantile(0.95, sum by (le,path) (rate(release_api_http_request_duration_seconds_bucket[5m])))' \
    > "${OUT_DIR}/prometheus/release-api-p95-latency.json" || true
else
  echo "Prometheus not reachable at ${PROM_URL}; skipping Prometheus API collection" \
    > "${OUT_DIR}/prometheus/skipped.txt"
fi

cat > "${OUT_DIR}/summary.txt" <<SUMMARY
Incident context collected at: ${TS}
Namespace: ${APP_NS}
Application: ${ARGOCD_APP}
Output directory: ${OUT_DIR}

Start investigation with:
1. app-workloads.txt
2. app-events.txt
3. argocd-application.txt
4. describes/deployment-release-api.txt
5. describes/pod-*.txt
6. logs/*-current.log
7. logs/*-previous.log
8. prometheus/alerts.json
SUMMARY

echo
echo "Incident context collected:"
echo "$OUT_DIR"
