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
    echo "Generating new Argo CD admin password and patching argocd-secret."
    # The ARGOCD_PASSWORD variable is made local to this function
    local ARGOCD_PASSWORD
    ARGOCD_PASSWORD=$(openssl rand -base64 10)
    echo -n "$ARGOCD_PASSWORD" > resources/.argocd-admin-password

    # Wait for the argocd-secret to be created by the controller
    until kubectl get secret argocd-secret -n argocd > /dev/null 2>&1; do
      echo "Waiting for argocd-secret to be created..."
      sleep 2
    done
    BCRYPT_HASH=$(argocd account bcrypt --password "$ARGOCD_PASSWORD")
    CURRENT_TIME=$(date +%Y-%m-%dT%H:%M:%SZ)
    kubectl -n argocd patch secret argocd-secret \
      -p "{\"stringData\": {
        \"admin.password\": \"$BCRYPT_HASH\",
        \"admin.passwordMtime\": \"$CURRENT_TIME\"
      }}"
    kubectl -n argocd rollout restart deployment argocd-server
  fi
}

echo "Waiting for cluster to be ready"
kubectl wait --for=condition=Available  -n kube-system deployment coredns
# The minus sign (-) at the end removes the taint
kubectl taint nodes desktop-control-plane node-role.kubernetes.io/control-plane:NoSchedule- || true

git config pull.rebase true

kubectl apply -f local-cluster/core/argocd/namespace.yaml
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for argocd controller to start"
sleep 5
kubectl wait --timeout=5m --for=condition=Available -n argocd deployment argocd-server
sleep 2

setup_argocd_password

# Create a CA Certificate for the ingress controller to use

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

application.sh --file local-cluster/core/cert-manager/application.yaml

# Install CA Certificate secret so Cert Manager can issue certificates using our CA

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

# Add CA Certificates to namespaces where it is required

namespace_list=$(local_or_global resources/local-ca-namespaces.txt)
export CA_CERT="$(cat resources/CA.cer)"
for nameSpace in $(cat $namespace_list); do
  export nameSpace
  cat $(local_or_global resources/local-ca-ns.yaml) |envsubst | kubectl apply -f -
  kubectl create configmap local-ca -n ${nameSpace} --from-file=resources/CA.cer --dry-run=client -o yaml >/tmp/ca.yaml
  kubectl apply -f /tmp/ca.yaml
done

kubectl apply -f local-cluster/core/cert-manager/cert-config.yaml

# Force a refresh of the Argo CD repo server to pick up the latest git changes
echo "Refreshing Argo CD repository cache..."
kubectl rollout restart deployment argocd-repo-server -n argocd
kubectl wait --for=condition=Available -n argocd deployment/argocd-repo-server --timeout=2m

application.sh --file local-cluster/core-services-app.yaml

# Apply the ingress appset
kubectl apply -f local-cluster/ingress-appset.yaml

# Wait for the ApplicationSet controller to create the Application
sleep 5
echo "Waiting for Argo CD ApplicationSet to generate the ingress-nginx application..."
kubectl wait --for=condition=ResourcesUpToDate=True applicationset/ingress -n argocd --timeout=2m
echo "ApplicationSet 'ingress' is up to date."

# Wait for the ingress-nginx application to be healthy
sleep 5
echo "Waiting for the ingress-nginx application to become healthy..."
kubectl wait --for=jsonpath='{.status.health.status}'=Healthy application/ingress -n argocd --timeout=5m
echo "Application 'ingress-nginx' is healthy."

echo "Issuing TLS certificate for Argo CD server..."
kubectl apply -f resources/argocd-server-cert.yaml
echo "Waiting for Argo CD server TLS secret to be created by cert-manager..."
until kubectl get secret argocd-server-tls -n argocd > /dev/null 2>&1; do
  sleep 2
done
echo "Argo CD server TLS secret is ready."

echo "Configuring Argo CD server for Ingress..."
envsubst < resources/argocd-ingress.yaml | kubectl apply -f -

echo "Restarting Argo CD server to apply Ingress configuration..."
kubectl rollout restart deployment argocd-server -n argocd
kubectl wait --for=condition=Available -n argocd deployment/argocd-server --timeout=2m

echo "Giving Argo CD server a moment to initialize..."
sleep 5

echo "Logging in to Argo CD via Ingress..."
ARGOCD_PASSWORD=$(cat resources/.argocd-admin-password)
# Retry login in case server is not immediately ready
for i in {1..5}; do
  # Note: --insecure is removed as we now have a fully trusted TLS chain
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

echo "Waiting for ingress service to be created..."
while ! kubectl get svc -n ingress-nginx ingress-ingress-nginx-controller > /dev/null 2>&1; do
    sleep 2
done
echo "Ingress service found."

export CLUSTER_IP=$(kubectl get svc -n ingress-nginx ingress-ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')

# Now that we have the cluster IP, update the params file and push to git again
cat <<EOF > local-cluster/config/cluster-params.yaml
dnsSuffix: ${local_dns}
clusterIP: "${CLUSTER_IP}"
storageClass: hostpath
EOF
git add local-cluster/config/cluster-params.yaml
if [[ `git status --porcelain` ]]; then
  git commit -m "update cluster params with cluster IP"
  git pull
  git push
fi

# Force another refresh so it picks up the clusterIP
echo "Refreshing Argo CD repository cache..."
kubectl rollout restart deployment argocd-repo-server -n argocd
kubectl wait --for=condition=Available -n argocd deployment/argocd-repo-server --timeout=2m

# With the full params in git, we can now apply the other appsets
kubectl apply -f local-cluster/vault-appset.yaml

# Wait for the ApplicationSet controller to create the Application
sleep 5
echo "Waiting for Argo CD ApplicationSet to generate the vault application..."
kubectl wait --for=condition=ResourcesUpToDate=True applicationset/vault -n argocd --timeout=2m
echo "ApplicationSet 'vault' is up to date."

echo "Configuring argocd-server for Ingress"
kubectl patch deployment argocd-server -n argocd --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--insecure"}]'
envsubst < resources/argocd-ingress.yaml | kubectl apply -f -

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

export CA_CERT=$(kubectl get configmap local-ca -n ingress-nginx -o jsonpath='{.data.CA\.cer}' | sed 's/^/          /')
envsubst < resources/grafana-datasources.yaml > local-cluster/addons/grafana/grafana-datasources.yaml

git add local-cluster/addons/grafana/grafana-datasources.yaml
if [[ `git status --porcelain` ]]; then
  git commit -m "grafana datasources"
  git pull
  git push
fi

application.sh --file local-cluster/addons.yaml

kubectl apply -f local-cluster/grafana-appset.yaml
kubectl apply -f local-cluster/mimir-appset.yaml
kubectl apply -f local-cluster/loki-appset.yaml
kubectl apply -f local-cluster/tempo-appset.yaml
kubectl apply -f local-cluster/otel-collector-appset.yaml
