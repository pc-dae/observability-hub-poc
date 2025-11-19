#!/bin/bash

set -euo pipefail

NAMESPACE="monitoring"

echo "🔍 Fetching pods from namespace: $NAMESPACE"
PODS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

if [ -z "$PODS" ]; then
    echo "🤷 No pods found in namespace '$NAMESPACE'"
    exit 0
fi

echo "Pods found: $(echo "$PODS" | wc -w | xargs) pods"
echo ""

for pod in $PODS; do
    echo "=================================================="
    echo "Pod: $pod"
    echo "=================================================="

    CONTAINERS=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)
    INIT_CONTAINERS=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null || true)
    
    ALL_CONTAINERS=$(echo "$CONTAINERS $INIT_CONTAINERS" | xargs)

    if [ -z "$ALL_CONTAINERS" ];
    then
        echo "  No containers found for pod '$pod'."
        continue
    fi

    for container in $ALL_CONTAINERS; do
        echo "--- Container: $container ---"
        
        # We use || true so that the script doesn't exit if grep finds no matches (which returns exit code 1)
        output=$(kubectl logs --tail=1000 -n "$NAMESPACE" "$pod" -c "$container" 2>/dev/null | grep -iE "error|warn" || true)

        if [ -n "$output" ]; then
            echo "$output"
        else
            echo "  No 'error' or 'warn' lines found in recent logs."
        fi
        echo "" # for spacing
    done
done

echo "✅ Log check complete."

kubectl get pod -n monitoring -o wide