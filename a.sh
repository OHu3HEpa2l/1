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

echo "2. Fetching live deployment YAML..."
kubectl get deployment $DEPLOYMENT -n $NAMESPACE -o yaml > current-deployment.yaml

echo "3. Injecting mysqld-exporter sidecar using sed..."
# Check if the sidecar is already injected to avoid duplicating it
if ! grep -q "name: mysqld-exporter" current-deployment.yaml; then
  # Define the YAML snippet with exact container-level indentation (6 spaces)
  read -r -d '' SIDECAR << 'EOF' || true
      - image: prom/mysqld-exporter:v0.17.2
        imagePullPolicy: IfNotPresent
        name: mysqld-exporter
        args:
        - --mysqld.username=exporter
        - --mysqld.address=localhost:3306
        env:
        - name: MYSQLD_EXPORTER_PASSWORD
          value: "MysqlMetrics2026!"
        ports:
        - containerPort: 9104
          name: metrics
          protocol: TCP
        resources: {}
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
EOF

  # Escape special characters for sed and insert right before 'dnsPolicy:'
  ESCAPED_SIDECAR=$(printf '%s\n' "$SIDECAR" | sed 's/[\&/]/\\&/g' | sed '$!s/$/\\/')
  sed -i "/dnsPolicy:/i \\$ESCAPED_SIDECAR" current-deployment.yaml
  echo "Sidecar injected successfully."
else
  echo "Sidecar already exists in deployment configuration."
fi

echo "4. Applying patched deployment..."
kubectl apply -f current-deployment.yaml

echo "5. Patching service to add metrics port..."
kubectl patch svc $SERVICE -n $NAMESPACE --type=json -p='[
  {"op": "add", "path": "/spec/ports/-", "value": {"name": "metrics", "port": 9104, "protocol": "TCP", "targetPort": 9104}}
]' 2>/dev/null || echo "Service port 9104 likely already exists."

echo "6. Applying ServiceMonitor..."
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

echo "7. Cleaning up temp files..."
rm -f current-deployment.yaml

echo "All tasks completed successfully!"