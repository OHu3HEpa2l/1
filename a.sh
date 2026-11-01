#!/bin/bash
set -e

NAMESPACE="default"
DEPLOYMENT="ucmysql"
SERVICE="ucmysql"

echo "1. Ensuring MySQL exporter secret exists..."
kubectl create secret generic mysql-exporter-secret \
  -n $NAMESPACE \
  --from-literal=DATA_SOURCE_NAME='exporter:MysqlMetrics2026!@(localhost:3306)/' \
  --dry-run=client -o yaml | kubectl apply -f -

echo "2. Fetching live deployment and patching mysqld-exporter sidecar..."
# Pull current deployment YAML
kubectl get deployment $DEPLOYMENT -n $NAMESPACE -o yaml > current-deployment.yaml

# Use Python (built into most systems) to safely insert the container before 'dnsPolicy' 
python3 -umal - << 'EOF'
import yaml

with open('current-deployment.yaml', 'r') as f:
    doc = yaml.safe_load(f)

# Define the sidecar container snippet
sidecar = {
    'image': 'prom/mysqld-exporter:v0.17.2',
    'imagePullPolicy': 'IfNotPresent',
    'name': 'mysqld-exporter',
    'args': ['--mysqld.username=exporter', '--mysqld.address=localhost:3306'],
    'env': [{'name': 'MYSQLD_EXPORTER_PASSWORD', 'value': 'MysqlMetrics2026!'}],
    'ports': [{'containerPort': 9104, 'name': 'metrics', 'protocol': 'TCP'}],
    'resources': {},
    'terminationMessagePath': '/dev/termination-log',
    'terminationMessagePolicy': 'File'
}

containers = doc['spec']['template']['spec']['containers']
# Check if exporter already exists to avoid duplication
if not any(c.get('name') == 'mysqld-exporter' for c in containers):
    containers.append(sidecar)

with open('patched-deployment.yaml', 'w') as f:
    yaml.safe_dump(doc, f)
EOF

echo "3. Applying patched deployment..."
kubectl apply -f patched-deployment.yaml

echo "4. Patching service to add port 9104..."
kubectl patch svc $SERVICE -n $NAMESPACE --type=json -p='[
  {"op": "add", "path": "/spec/ports/-", "value": {"name": "metrics", "port": 9104, "protocol": "TCP", "targetPort": 9104}}
]' || echo "Service port might already exist, continuing..."

echo "5. Applying ServiceMonitor..."
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ucmysql
  namespace: monitoring
  labels:
    release: prometheus
spec:
  namespaceSelector:
    matchNames:
    - default
  selector:
    matchLabels:
      app: ucmysql
  endpoints:
  - port: metrics
    interval: 30s
EOF

echo "6. Waiting for rollout..."
kubectl rollout status deployment/$NET_DEPLOYMENT -n $NAMESPACE || true
rm -f current-deployment.yaml patched-deployment.yaml

echo "Automation completed successfully!"