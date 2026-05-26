# elk-stack-kubernetes

> Production ELK Stack (Elasticsearch · Logstash · Kibana · Filebeat) on Kubernetes — structured log pipelines for 100+ microservices, ILM cost management, and Kibana observability dashboards.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster                                                   │
│                                                                       │
│  ┌─────────────────┐     ┌──────────────────────────────────────┐    │
│  │  Microservices  │────►│  Filebeat DaemonSet                  │    │
│  │  nginx pods     │     │  (autodiscover via k8s annotations)  │    │
│  └─────────────────┘     └──────────────┬───────────────────────┘    │
│                                         │ beats protocol              │
│                          ┌──────────────▼───────────────────────┐    │
│                          │  Logstash (2 replicas)                │    │
│                          │  ├── microservices pipeline           │    │
│                          │  ├── nginx access log pipeline        │    │
│                          │  └── kubernetes metadata pipeline     │    │
│                          └──────────────┬───────────────────────┘    │
│                                         │ HTTPS + mTLS               │
│                          ┌──────────────▼───────────────────────┐    │
│                          │  Elasticsearch (3 nodes, AZ-spread)  │    │
│                          │  ├── Hot tier (SSD, fast ingest)     │    │
│                          │  ├── Warm tier (shrink + forcemerge) │    │
│                          │  ├── Cold tier (frozen indices)      │    │
│                          │  └── ILM (auto hot→warm→cold→delete) │    │
│                          └──────────────┬───────────────────────┘    │
│                                         │                            │
│                          ┌──────────────▼───────────────────────┐    │
│                          │  Kibana (2 replicas)                  │    │
│                          │  └── Ingress (cert-manager TLS)       │    │
│                          └──────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

## ILM Policy Summary

| Index Pattern | Hot | Warm | Cold | Delete |
|---------------|-----|------|------|--------|
| `microservices-*` | rollover at 50GB/1d | 3d → shrink+merge | 14d → freeze | **30d** |
| `nginx-access-*` | rollover at 25GB/1d | 7d → shrink+merge | 30d → freeze | **90d** |
| `k8s-logs-*` | rollover at 50GB/1d | 5d → shrink+merge | 15d → freeze | **45d** |

## Quickstart

```bash
# 1. Add Elastic Helm repo
helm repo add elastic https://helm.elastic.co
helm repo update

# 2. Create TLS certificates (or use cert-manager)
./scripts/generate-certs.sh   # see script for details

# 3. Deploy the full stack
./scripts/deploy.sh

# 4. Watch rollout
kubectl get pods -n logging -w
```

## Log Enrichment

Filebeat uses Kubernetes autodiscovery hints. Add these annotations to any pod:

```yaml
annotations:
  co.elastic.logs/enabled: "true"
  co.elastic.logs/json.keys_under_root: "true"
  co.elastic.logs/json.overwrite_keys: "true"
```

Logstash enriches each log event with:
- `k8s_namespace`, `k8s_pod`, `k8s_container`
- `service.name`, `service.version` (from JSON fields)
- `geoip` (nginx access logs)
- `user_agent` (nginx access logs)

## Structure

```
elk-stack-kubernetes/
├── helm/
│   ├── elasticsearch/values.yaml   # 3-node cluster, KMS, ILM
│   ├── logstash/values.yaml        # multi-pipeline, mTLS
│   ├── kibana/values.yaml          # HA, ingress, encryption keys
│   └── filebeat/values.yaml        # DaemonSet, autodiscover
├── ilm/
│   └── policies.json               # hot/warm/cold/delete lifecycle
├── kibana/
│   └── dashboards/                 # pre-built NDJSON dashboards
├── network-policies/
│   └── elk-network-policies.yaml   # deny-all + selective allow
└── scripts/
    └── deploy.sh                   # one-command deploy
```

## Tech Stack

**Elasticsearch 8 · Logstash · Kibana · Filebeat · Helm · Kubernetes · cert-manager**
