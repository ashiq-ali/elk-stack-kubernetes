# elk-stack-kubernetes

> Production ELK Stack (Elasticsearch · Logstash · Kibana · Filebeat) on Kubernetes with structured logging pipelines for 100+ microservices, ILM cost management, and pre-built observability dashboards.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Elasticsearch](https://img.shields.io/badge/Elasticsearch-8.x-005571?logo=elasticsearch)](https://elastic.co)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.28%2B-326CE5?logo=kubernetes)](https://kubernetes.io)
[![Helm](https://img.shields.io/badge/Helm-3.x-0F1689?logo=helm)](https://helm.sh)

---

## Architecture

> 📐 **[Open in Excalidraw](docs/architecture.excalidraw)** — interactive diagram you can edit at [excalidraw.com](https://excalidraw.com)

```
  App Pods (100+ microservices)
  ├── nginx          ─┐
  ├── api-gateway    ─┤
  ├── auth-service   ─┤──► Filebeat DaemonSet ──► Logstash
  ├── payment-svc    ─┤         (per node)         ├── k8s pipeline     ─┐
  └── ...            ─┘                            ├── nginx pipeline    ─┤
                                                   └── microservice pipeline ─┤
                                                                              ▼
                                                              Elasticsearch (3-node cluster)
                                                              └── ILM Policy
                                                                  ├── hot  (SSD, 7d)
                                                                  ├── warm (HDD, 30d)
                                                                  ├── cold (frozen, 90d)
                                                                  └── delete
                                                                        ▼
                                                              Kibana Dashboards
                                                              ├── Microservices Overview
                                                              ├── Error Rate by Service
                                                              ├── Latency Percentiles
                                                              └── Infrastructure Health
```

---

## Table of Contents

- [Why this setup](#why-this-setup)
- [Prerequisites](#prerequisites)
- [Quick Deploy](#quick-deploy)
- [Elasticsearch Configuration](#elasticsearch-configuration)
- [Logstash Pipelines](#logstash-pipelines)
- [Filebeat DaemonSet](#filebeat-daemonset)
- [Kibana Dashboards](#kibana-dashboards)
- [Index Lifecycle Management](#index-lifecycle-management)
- [Network Policies](#network-policies)
- [Scaling Guide](#scaling-guide)
- [Cost Estimate](#cost-estimate)
- [Troubleshooting](#troubleshooting)

---

## Why this setup

Running the ELK stack at scale for 100+ microservices requires deliberate choices:

| Challenge | Solution in this repo |
|-----------|----------------------|
| Too many index patterns | Service-scoped indices `logs-<service>-<date>` |
| Storage cost grows unbounded | ILM hot→warm→cold→delete cycle |
| Unstructured logs from legacy services | Logstash `grok` + `json` pipelines with fallback |
| Single node is a SPOF | 3-node Elasticsearch cluster with shard allocation awareness |
| ELK traffic pollutes app namespace | Network policies — Filebeat→Logstash→ES only on required ports |
| Filebeat restarts lose position | Filebeat stores registry on PVC, not emptyDir |

---

## Prerequisites

| Tool | Version |
|------|---------|
| kubectl | ≥ 1.28 |
| helm | ≥ 3.12 |
| A K8s cluster | GKE / EKS / AKS with ≥ 12 vCPU, ≥ 24 GB RAM available |
| StorageClass | SSD-backed (e.g. `premium-rwo` on GKE, `gp3` on EKS) |

---

## Quick Deploy

```bash
# 1. Clone
git clone https://github.com/ashiq-ali/elk-stack-kubernetes
cd elk-stack-kubernetes

# 2. Add Helm repos
helm repo add elastic https://helm.elastic.co
helm repo update

# 3. Deploy (all components)
./scripts/deploy.sh

# Or step by step:
helm upgrade --install elasticsearch elastic/elasticsearch \
  -f helm/elasticsearch/values.yaml \
  --namespace logging --create-namespace --wait

helm upgrade --install logstash elastic/logstash \
  -f helm/logstash/values.yaml \
  --namespace logging --wait

helm upgrade --install kibana elastic/kibana \
  -f helm/kibana/values.yaml \
  --namespace logging --wait

helm upgrade --install filebeat elastic/filebeat \
  -f helm/filebeat/values.yaml \
  --namespace logging --wait

# 4. Verify all pods running
kubectl get pods -n logging

# 5. Access Kibana
kubectl port-forward svc/kibana-kibana 5601:5601 -n logging
# Open http://localhost:5601
```

> **First deploy takes ~5 minutes** — Elasticsearch waits for a 3-node green cluster.

---

## Elasticsearch Configuration

`helm/elasticsearch/values.yaml` sets up a 3-node cluster with:

```yaml
replicas: 3

resources:
  requests:
    cpu: "1000m"
    memory: "4Gi"
  limits:
    cpu: "2000m"
    memory: "4Gi"

# JVM heap = 50% of container memory limit
esJavaOpts: "-Xmx2g -Xms2g"

# SSD-backed storage per node
volumeClaimTemplate:
  storageClassName: premium-rwo   # Change to match your cluster
  resources:
    requests:
      storage: 100Gi

# Spread nodes across availability zones
antiAffinity: "hard"

# Shard allocation awareness by AZ
esConfig:
  elasticsearch.yml: |
    cluster.routing.allocation.awareness.attributes: topology.kubernetes.io/zone
```

**Index naming convention:**
- `logs-{service}-{YYYY.MM.dd}` — one index per service per day
- `logs-nginx-{YYYY.MM.dd}` — nginx access logs separately
- `logs-k8s-events-{YYYY.MM.dd}` — Kubernetes events

---

## Logstash Pipelines

Three pipelines run in parallel, each handling a distinct log format.

### Microservices Pipeline (`pipelines/microservices.conf`)

Handles structured JSON logs from all application services:

```
Input: Filebeat → TCP 5044
Filter:
  - json parse (most services emit structured JSON)
  - if parse fails: grok fallback for unstructured text
  - kubernetes metadata enrichment (namespace, pod, container, node)
  - geo_ip on client_ip (if present)
  - user-agent parse
  - mutate: add [service] field from kubernetes.labels.app
Output:
  - elasticsearch index: "logs-%{[service]}-%{+YYYY.MM.dd}"
  - dead letter queue for unparseable messages
```

### Nginx Pipeline (`pipelines/nginx.conf`)

Parses nginx combined log format and enriches with geo data:

```
Input: Filebeat → TCP 5045
Filter:
  - grok: nginx combined access log
  - date: parse request timestamp
  - geoip: client IP → country, city, lat/lon
  - useragent: browser, OS, device
  - mutate: convert response_time to float
Output:
  - elasticsearch index: "logs-nginx-%{+YYYY.MM.dd}"
```

### Kubernetes Events Pipeline (`pipelines/kubernetes.conf`)

Collects Kubernetes events (pod failures, OOMKills, scheduling errors):

```
Input: Filebeat → TCP 5046
Filter:
  - json parse kubernetes event JSON
  - translate: reason code → human-readable description
  - if event.type == "Warning": tag as [alert]
Output:
  - elasticsearch index: "logs-k8s-events-%{+YYYY.MM.dd}"
```

---

## Filebeat DaemonSet

Filebeat runs on every node, tailing all container logs:

```yaml
# Key settings in helm/filebeat/values.yaml

daemonset:
  hostNetworking: false
  tolerations:
    - effect: NoSchedule   # run on tainted nodes too
      operator: Exists

  # Autodiscover: pick up new pods automatically
  filebeatConfig:
    filebeat.yml: |
      filebeat.autodiscover:
        providers:
          - type: kubernetes
            node: ${NODE_NAME}
            hints.enabled: true
            hints.default_config:
              type: container
              paths:
                - /var/log/containers/*${data.kubernetes.container.id}.log

      # Route to correct Logstash pipeline based on pod labels
      output.logstash:
        hosts: ["logstash-logstash:5044"]
```

Pods opt into specific pipelines via labels:
```yaml
metadata:
  labels:
    log-pipeline: microservices   # → port 5044
    # log-pipeline: nginx         # → port 5045
```

---

## Kibana Dashboards

Pre-built dashboards are in `kibana/dashboards/`. Import them via:

```bash
curl -X POST http://kibana:5601/api/saved_objects/_import \
  -H "kbn-xsrf: true" \
  --form file=@kibana/dashboards/microservices-overview.ndjson
```

| Dashboard | What it shows |
|-----------|--------------|
| **Microservices Overview** | Request rate, error rate, latency P50/P95/P99 per service |
| **Error Deep Dive** | Error messages grouped by service and error type |
| **Infrastructure Health** | Pod restarts, OOMKills, node events |
| **Nginx Traffic** | Request volume, status codes, top URLs, geo map |
| **SLA Summary** | 7d/30d error rate per service, useful for SLO review |

---

## Index Lifecycle Management

ILM automatically transitions indices through storage tiers based on age and size, keeping costs controlled:

```json
// ilm/policies.json
{
  "logs-default": {
    "phases": {
      "hot":    { "min_age": "0ms",  "actions": { "rollover": { "max_size": "50gb", "max_age": "7d" }, "set_priority": { "priority": 100 } } },
      "warm":   { "min_age": "7d",   "actions": { "shrink": { "number_of_shards": 1 }, "forcemerge": { "max_num_segments": 1 }, "set_priority": { "priority": 50 } } },
      "cold":   { "min_age": "30d",  "actions": { "freeze": {}, "set_priority": { "priority": 0 } } },
      "delete": { "min_age": "90d",  "actions": { "delete": {} } }
    }
  }
}
```

Apply policies:
```bash
curl -X PUT "http://elasticsearch:9200/_ilm/policy/logs-default" \
  -H "Content-Type: application/json" \
  -d @ilm/policies.json
```

Storage cost profile (per 1M log lines/day):
- Hot tier (SSD): 7 days → ~7 GB → ~$1.40/month
- Warm tier (HDD): 23 days → ~23 GB → ~$0.46/month
- Cold tier (frozen): 60 days → ~60 GB → ~$0.60/month
- Auto-deleted after 90 days

---

## Network Policies

`network-policies/` locks down ELK traffic to only required flows:

```yaml
# Only Filebeat can reach Logstash
# Only Logstash can reach Elasticsearch
# Only Kibana can reach Elasticsearch
# Kibana is reachable only from ingress-nginx
# No direct pod-to-Elasticsearch access from apps
```

Apply:
```bash
kubectl apply -f network-policies/ -n logging
```

---

## Scaling Guide

| Logs/day | Elasticsearch nodes | Logstash replicas | Heap (ES) |
|----------|--------------------|--------------------|-----------|
| < 10M | 3 × `4Gi` | 1 | 2g |
| 10M–100M | 3 × `8Gi` | 2–3 | 4g |
| 100M–1B | 5+ × `16Gi` | 4–6 | 8g |
| > 1B | Dedicated hot/warm/cold node roles | 8+ | 16g |

Logstash horizontal scaling:
```bash
kubectl scale deployment logstash-logstash --replicas=4 -n logging
```

Elasticsearch vertical scaling — update `helm/elasticsearch/values.yaml` and re-apply:
```bash
helm upgrade elasticsearch elastic/elasticsearch \
  -f helm/elasticsearch/values.yaml \
  --namespace logging
```

---

## Cost Estimate

Approximate monthly costs on GKE (eu-west-2 equivalent):

| Resource | Spec | ~Cost/month |
|----------|------|-------------|
| Elasticsearch | 3 × n2-standard-4 (4 vCPU, 16 GB) | $320 |
| Elasticsearch storage | 3 × 100 GB SSD + 300 GB HDD (warm) | $65 |
| Logstash | 2 × n2-standard-2 | $100 |
| Kibana | 1 × n2-standard-2 | $50 |
| Filebeat | DaemonSet (minimal resources) | ~$0 |
| **Total** | | **~$535/month** |

---

## Troubleshooting

**Elasticsearch cluster health is `yellow` or `red`**

```bash
curl http://elasticsearch:9200/_cluster/health?pretty
curl http://elasticsearch:9200/_cluster/allocation/explain?pretty
# Red: unassigned shards. Check storage capacity and node availability.
# Yellow: replica shards unassigned. OK on a single-node cluster.
```

**Logstash pipeline not processing messages**

```bash
kubectl logs -n logging deployment/logstash-logstash
# Check dead letter queue:
curl http://elasticsearch:9200/logstash-dlq-*/_search?size=5\&pretty
```

**Filebeat not shipping logs from a specific pod**

```bash
kubectl logs -n logging daemonset/filebeat | grep <pod-name>
# Check Filebeat registry:
kubectl exec -n logging ds/filebeat -- cat /usr/share/filebeat/data/registry/filebeat/log.json
```

**Kibana shows "No results" despite logs existing**

Check the index pattern. The default index pattern is `logs-*`. If your logs are in `logs-api-service-2024.01.*`, open Kibana → Stack Management → Index Patterns → verify `logs-*` covers them.

**ILM policy not applied to existing indices**

```bash
# Manually apply ILM policy to an index
curl -X PUT "http://elasticsearch:9200/logs-api-service-2024.01.01/_settings" \
  -H "Content-Type: application/json" \
  -d '{"index.lifecycle.name": "logs-default"}'
```

---

*Built to demonstrate the ELK observability stack that monitored 100+ microservices in production at Eviden-Atos, where it processed billions of log events monthly.*
