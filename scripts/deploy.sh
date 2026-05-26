#!/usr/bin/env bash
# deploy.sh — deploy the full ELK stack to Kubernetes
#
# Usage:
#   ./scripts/deploy.sh
#   ES_HOST=https://elasticsearch:9200 ./scripts/deploy.sh   # custom ES host
#
# Prerequisites: helm, kubectl, curl
set -euo pipefail

NAMESPACE="${NAMESPACE:-logging}"
ES_HOST="${ES_HOST:-https://elasticsearch-master.logging.svc.cluster.local:9200}"
ES_USER="${ES_USER:-elastic}"
ES_PASSWORD="${ES_PASSWORD:-}"  # set via environment or secret
CHART_VERSION_ES="${CHART_VERSION_ES:-8.5.1}"
CHART_VERSION_LOGSTASH="${CHART_VERSION_LOGSTASH:-8.5.1}"
CHART_VERSION_KIBANA="${CHART_VERSION_KIBANA:-8.5.1}"
CHART_VERSION_FILEBEAT="${CHART_VERSION_FILEBEAT:-8.5.1}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${GREEN}[elk-deploy]${NC} $*"; }
warn() { echo -e "${YELLOW}[elk-deploy]${NC} $*"; }
err()  { echo -e "${RED}[elk-deploy]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}══ $* ══${NC}"; }

check_prerequisites() {
  step "Checking prerequisites"
  for cmd in helm kubectl curl; do
    command -v "$cmd" &>/dev/null || err "Missing: $cmd"
  done
  helm repo add elastic https://helm.elastic.co --force-update
  helm repo update elastic
  log "Prerequisites OK"
}

create_namespace() {
  step "Creating namespace: $NAMESPACE"
  kubectl get namespace "$NAMESPACE" &>/dev/null || \
    kubectl create namespace "$NAMESPACE"
  kubectl label namespace "$NAMESPACE" \
    app.kubernetes.io/managed-by=helm \
    --overwrite
  log "Namespace ready"
}

deploy_elasticsearch() {
  step "Deploying Elasticsearch $CHART_VERSION_ES"
  helm upgrade --install elasticsearch elastic/elasticsearch \
    --namespace "$NAMESPACE" \
    --version "$CHART_VERSION_ES" \
    --values helm/elasticsearch/values.yaml \
    --wait \
    --timeout 10m
  log "Elasticsearch deployed"
}

deploy_logstash() {
  step "Deploying Logstash $CHART_VERSION_LOGSTASH"
  helm upgrade --install logstash elastic/logstash \
    --namespace "$NAMESPACE" \
    --version "$CHART_VERSION_LOGSTASH" \
    --values helm/logstash/values.yaml \
    --wait \
    --timeout 5m
  log "Logstash deployed"
}

deploy_kibana() {
  step "Deploying Kibana $CHART_VERSION_KIBANA"
  helm upgrade --install kibana elastic/kibana \
    --namespace "$NAMESPACE" \
    --version "$CHART_VERSION_KIBANA" \
    --values helm/kibana/values.yaml \
    --wait \
    --timeout 5m
  log "Kibana deployed"
}

deploy_filebeat() {
  step "Deploying Filebeat $CHART_VERSION_FILEBEAT"
  helm upgrade --install filebeat elastic/filebeat \
    --namespace "$NAMESPACE" \
    --version "$CHART_VERSION_FILEBEAT" \
    --values helm/filebeat/values.yaml \
    --wait \
    --timeout 5m
  log "Filebeat deployed"
}

apply_network_policies() {
  step "Applying network policies"
  kubectl apply -f network-policies/elk-network-policies.yaml
  log "Network policies applied"
}

apply_ilm_policies() {
  step "Applying ILM policies"

  if [[ -z "$ES_PASSWORD" ]]; then
    warn "ES_PASSWORD not set — skipping ILM policy application"
    warn "Run manually: curl -X PUT $ES_HOST/_ilm/policy/<name> -d @ilm/policies.json"
    return
  fi

  local policies=("microservices-policy" "nginx-access-policy" "k8s-logs-policy")
  for policy in "${policies[@]}"; do
    local body
    body=$(python3 -c "
import json, sys
with open('ilm/policies.json') as f:
    data = json.load(f)
print(json.dumps(data.get('$policy', {})))
")
    curl -s -X PUT "$ES_HOST/_ilm/policy/$policy" \
      -u "$ES_USER:$ES_PASSWORD" \
      -H "Content-Type: application/json" \
      -d "$body" \
      --insecure | python3 -c "import sys,json; d=json.load(sys.stdin); print('  ✅' if d.get('acknowledged') else '  ❌ ' + str(d))"
    log "ILM policy '$policy' applied"
  done
}

print_status() {
  step "Deployment complete 🎉"
  echo ""
  kubectl get pods -n "$NAMESPACE"
  echo ""
  log "Kibana: https://kibana.example.com"
  log "Elasticsearch: $ES_HOST"
}

main() {
  check_prerequisites
  create_namespace
  deploy_elasticsearch
  deploy_logstash
  deploy_kibana
  deploy_filebeat
  apply_network_policies
  apply_ilm_policies
  print_status
}

main "$@"
