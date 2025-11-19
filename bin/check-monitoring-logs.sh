#!/bin/bash

set -euo pipefail

NAMESPACE="monitoring"
APP_FILTER=""

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --app)
      APP_FILTER="$2"
      shift # past argument
      shift # past value
      ;;
    *) # unknown option
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

echo "🔍 Fetching pods from namespace: $NAMESPACE"
PODS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

if [ -n "$APP_FILTER" ]; then
    echo "Filtering for pods starting with: $APP_FILTER"
    PODS=$(echo "$PODS" | tr ' ' '\n' | grep "^$APP_FILTER" | tr '\n' ' ')
fi

if [ -z "$PODS" ]; then
    if [ -n "$APP_FILTER" ]; then
        echo "🤷 No pods found in namespace '$NAMESPACE' starting with '$APP_FILTER'"
    else
        echo "🤷 No pods found in namespace '$NAMESPACE'"
    fi
    exit 0
fi

echo "Pods found: $(echo "$PODS" | wc -w | xargs) pods"
echo ""

for pod in $PODS; do
    echo "==================================================" > /tmp/monitoring-logs.txt
    echo "Pod: $pod" >> /tmp/monitoring-logs.txt
    echo "==================================================" >> /tmp/monitoring-logs.txt

    CONTAINERS=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)
    INIT_CONTAINERS=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null || true)
    
    ALL_CONTAINERS=$(echo "$CONTAINERS $INIT_CONTAINERS" | xargs)

    if [ -z "$ALL_CONTAINERS" ]; then
        continue
    fi
    first=true
    for container in $ALL_CONTAINERS; do
        # We use || true so that the script doesn't exit if grep finds no matches (which returns exit code 1)
        output=$(kubectl logs --tail=1000 -n "$NAMESPACE" "$pod" -c "$container" 2>/dev/null | grep -iE "error|warn" | tail -10|| true)

        if [ -n "$output" ]; then
            if [ "$first" = true ]; then
                cat /tmp/monitoring-logs.txt
                first=false
            fi
            echo "--- Container: $container ---"
            echo "$output"
        fi
        echo "" # for spacing
    done
done

echo "✅ Log check complete."

kubectl get pod -n monitoring -o wide