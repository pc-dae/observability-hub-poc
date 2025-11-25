#!/usr/bin/env bash

# Utility setting local kubernetes cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug]" >&2
    echo "This script will initialize docker kubernetes" >&2
    echo "  --debug: emmit debugging information" >&2
}

function args()
{
  wait=1
  bootstrap=0
  reset=0
  debug_str=""
  cluster_type=""
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
               "-h") usage; exit;;
           "--help") usage; exit;;
               "-?") usage; exit;;
        *) if [ "${arg_list[${arg_index}]:0:2}" == "--" ];then
               echo "invalid argument: ${arg_list[${arg_index}]}" >&2
               usage; exit
           fi;
           break;;
    esac
    (( arg_index+=1 ))
  done
}

function wait_for_app_sync_and_health() {
  local name=$1
  echo "Waiting for application '$name' to be created..."
  until kubectl get application $name -n argocd > /dev/null 2>&1; do
    echo "  - Application '$name' not found yet. Retrying in 2 seconds..."
    sleep 2
  done
  echo "Application '$name' found. Waiting for it to become Healthy and Synced..."

  local timeout=300 # 5 minutes
  local start_time=$(date +%s)
  
  while true; do
    local current_time=$(date +%s)
    if [ $((current_time - start_time)) -ge $timeout ]; then
      echo "Error: Timeout waiting for application '$name' to be Healthy and Synced."
      echo "--- Describing Application '$name' for debugging ---"
      kubectl describe application $name -n argocd
      echo "----------------------------------------------------"
      exit 1
    fi

    local status_json=$(kubectl get application $name -n argocd -o json 2>/dev/null)
    if [ -z "$status_json" ]; then
        sleep 2
        continue
    fi

    local health_status=$(echo "$status_json" | jq -r '.status.health.status // "Unknown"')
    local sync_status=$(echo "$status_json" | jq -r '.status.sync.status // "Unknown"')

    if [ "$health_status" == "Healthy" ] && [ "$sync_status" == "Synced" ]; then
      echo "Application '$name' is Healthy and Synced."
      return 0
    fi
    
    echo "  - Current state for '$name': Health=$health_status, Sync=$sync_status. Retrying in 5 seconds..."
    sleep 5
  done
}

function apply_and_wait() {
  local application_file=$1
  local name=$(yq '.metadata.name' $application_file)
  kubectl apply -f $application_file
  wait_for_app_sync_and_health "$name"
}

args "$@"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/envs.sh

if [ -n "$debug_str" ]; then
  env | sort
fi

b64w=""

export LOCAL_DNS="$local_dns"

function setup_argocd_password() {
  echo "Setting up Argo CD password..."
  if [ -f "resources/.argocd-admin-password" ]; then
    echo "Using existing generated Argo CD admin password."
  else
    echo "Generating new Argo CD admin password..."
    local ARGOCD_PASSWORD
    ARGOCD_PASSWORD=$(openssl rand -base64 12)
    echo -n "$ARGOCD_PASSWORD" > resources/.argocd-admin-password
  fi
}

function patch_argocd_secret() {
  setup_argocd_password
  echo "Patching argocd-secret..."
  local ARGOCD_PASSWORD
  ARGOCD_PASSWORD=$(cat resources/.argocd-admin-password)
  local BCRYPT_HASH
  BCRYPT_HASH=$(argocd account bcrypt --password "$ARGOCD_PASSWORD")

  # Wait for the argocd-secret to be created by the controller
  until kubectl get secret argocd-secret -n argocd > /dev/null 2>&1; do
    echo "Waiting for argocd-secret to be created..."
    sleep 2
  done
  # Ensure initial secret is gone before applying
  kubectl delete secret argocd-initial-admin-secret -n argocd --ignore-not-found=true

  kubectl -n argocd patch secret argocd-secret \
    -p '{"data": {"admin.password": "'$(echo -n "$BCRYPT_HASH" | base64 -w 0)'", "admin.passwordMtime": "'$(date +%Y-%m-%dT%H:%M:%SZ | base64 -w 0)'"}}'
  echo "Patched argocd-secret with new password hash."
}

function setup_grafana_password() {
  echo "Setting up Grafana admin password..."
  local GRAFANA_PASSWORD_FILE="resources/.grafana-admin-password"
  if [ -f "$GRAFANA_PASSWORD_FILE" ]; then
    echo "Using existing generated Grafana admin password."
  else
    echo "Generating new Grafana admin password..."
    openssl rand -base64 12 > "$GRAFANA_PASSWORD_FILE"
  fi
  
  # Create or update the Kubernetes secret for Grafana
  local GRAFANA_PASSWORD
  GRAFANA_PASSWORD=$(cat "$GRAFANA_PASSWORD_FILE")
  kubectl create secret generic grafana-admin-credentials \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$GRAFANA_PASSWORD" \
    -n grafana --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret 'grafana-admin-credentials' created/updated."
}

function setup_cluster_params() {
  set +e
  THE_CLUSTER_IP="$(kubectl get svc -n ingress-nginx ingress-ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  set -e
  if [ -n "$THE_CLUSTER_IP" ]; then
    export CLUSTER_IP="${THE_CLUSTER_IP}"
  else
    export CLUSTER_IP="TBA"
  fi
  
  # Perform substitution for simple values
  cat resources/cluster-params.yaml | envsubst > local-cluster/config/cluster-params.yaml
  
  # Append the multi-line CA certificate directly to avoid envsubst parsing issues
  echo "" >> local-cluster/config/cluster-params.yaml
  echo "caCert: |" >> local-cluster/config/cluster-params.yaml
  sed 's/^/  /' resources/CA.cer >> local-cluster/config/cluster-params.yaml

  git add local-cluster/config/cluster-params.yaml
  commit_and_push "update cluster params"
}

function commit_and_push() {
  if [[ `git status --porcelain` ]]; then
    git commit -m "$@"
    git pull
    git push
  fi
  # Force a refresh of the Argo CD repo server to pick up the latest git changes
  echo "Refreshing Argo CD repository cache..."
  kubectl rollout restart deployment argocd-repo-server -n argocd
  kubectl wait --for=condition=Available -n argocd deployment/argocd-repo-server --timeout=2m
}

function wait_for_appset() {
  echo "Waiting for Argo CD ApplicationSet $1 to be created..."
  until kubectl get applicationset $1 -n argocd > /dev/null 2>&1; do
    sleep 2
  done
  echo "Waiting for Argo CD ApplicationSet to create the application..."
  kubectl wait --for=jsonpath='{.metadata.name}'=$1 applicationset/$1 -n argocd --timeout=2m
  echo "ApplicationSet '$1' created."
}

function wait_for_app() {
  wait_for_app_sync_and_health "$1"
}

function config_argocd_ingress() {
  echo "Configuring Argo CD server for Ingress..."
  # Add the --insecure flag to the argocd-server deployment.
  # This tells the server that TLS is being terminated upstream by the Ingress.
  kubectl patch deployment argocd-server -n argocd --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--insecure"}]'

  # Set the public URL in the argocd-cm configmap
  kubectl patch configmap argocd-cm -n argocd --type merge -p '{"data":{"url": "https://argocd.'${LOCAL_DNS}'"}}'

  apply_and_wait "local-cluster/argocd-config/application.yaml"
  
  echo "Restarting Argo CD server and Ingress to apply Ingress configuration..."
  kubectl rollout restart deployment argocd-server -n argocd
  deployment_name=$(kubectl get deployments -n ingress-nginx -o jsonpath='{.items[0].metadata.name}')
  kubectl rollout restart deployment -n ingress-nginx $deployment_name
  kubectl wait --for=condition=Available -n argocd deployment/argocd-server --timeout=2m
  kubectl wait --for=condition=Available -n argocd deployment/argocd-repo-server --timeout=2m
  kubectl wait --for=condition=Available -n ingress-nginx deployment/ingress-ingress-nginx-controller --timeout=2m

  echo "Giving services a moment to initialize..."
  sleep 30

  echo "Logging in to Argo CD via Ingress..."
  ARGOCD_PASSWORD=$(cat resources/.argocd-admin-password)
  # Retry login in case server is not immediately ready
  for i in {1..5}; do
    if argocd login "argocd.${LOCAL_DNS}" --grpc-web --username admin --password "$ARGOCD_PASSWORD"; then
      echo "Argo CD login successful."
      break
    fi
    if [ $i -eq 5 ]; then
      echo "Failed to log in to Argo CD after multiple attempts."
      exit 1
    fi
    echo "Login failed, retrying in 5 seconds..."
    sleep 5
  done
}


echo "Waiting for cluster to be ready"
kubectl wait --for=condition=Available  -n kube-system deployment coredns
# The minus sign (-) at the end removes the taint
kubectl taint nodes desktop-control-plane node-role.kubernetes.io/control-plane:NoSchedule- || true

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for argocd controller to start"
kubectl wait --for=condition=Available -n argocd deployment/argocd-server --timeout=5m

patch_argocd_secret

if [ -f resources/CA.cer ]; then
  echo "Certificate Authority already exists"
else
  ca-cert.sh $debug_str
  git add resources/CA.cer
  if [[ `git status --porcelain` ]]; then
    git commit -m "add CA certificate"
    git pull
    git push
  fi
fi

setup_cluster_params

apply_and_wait "local-cluster/namespaces/application.yaml"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ca-key-pair
  namespace: cert-manager
data:
  tls.crt: $(base64 ${b64w} -i resources/CA.cer)
  tls.key: $(base64 ${b64w} -i resources/CA.key)
EOF

apply_and_wait "local-cluster/cert-manager/application.yaml"

apply_and_wait "local-cluster/core-services-app.yaml"

apply_and_wait "local-cluster/ingress-application.yaml"

wait_for_appset ingress

wait_for_app ingress

echo "Waiting for ingress service to be created..."
while ! kubectl get svc -n ingress-nginx ingress-ingress-nginx-controller > /dev/null 2>&1; do
    sleep 2
done
echo "Ingress service found."

setup_cluster_params

config_argocd_ingress

# With the full params in git, we can now apply the other appsets

apply_and_wait "local-cluster/vault-application.yaml"

wait_for_appset vault

wait_for_app vault

# Wait for vault to start
while ( true ); do
  echo "Waiting for vault to start"
  set +e
  started="$(kubectl get pod/vault-0 -n vault -o json 2>/dev/null | jq -r '.status.containerStatuses[0].started')"
  set -e
  if [ "$started" == "true" ]; then
    break
  fi
  sleep 5
done

# Initialize vault
vault-init.sh $debug_str --tls-skip
vault-unseal.sh $debug_str --tls-skip

export VAULT_TOKEN="$(jq -r '.root_token' resources/.vault-init.json)"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
  namespace: vault
data:
  vault_token: $(echo -n "$VAULT_TOKEN" | base64 ${b64w})
EOF

vault-secrets-config.sh $debug_str --tls-skip

secrets.sh $debug_str --tls-skip --secrets $PWD/resources/secrets/github-secrets.sh

sleep 10
kubectl rollout restart deployment -n external-secrets external-secrets

apply_and_wait "local-cluster/grafana-datasources/application.yaml"

apply_and_wait "local-cluster/addons.yaml"

setup_grafana_password

# Apply appsets
apply_and_wait "local-cluster/addons-appsets.yaml"
