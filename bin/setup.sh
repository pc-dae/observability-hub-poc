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

echo "Waiting for cluster to be ready"
kubectl wait --for=condition=Available  -n kube-system deployment coredns

git config pull.rebase true

kubectl apply -f local-cluster/core/argocd/namespace.yaml
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for argocd controller to start"
sleep 5
kubectl wait --timeout=5m --for=condition=Available -n argocd deployment argocd-server
sleep 2

PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
nohup kubectl port-forward svc/argocd-server -n argocd 8080:443 >/tmp/argocd-port-forward.log 2>&1 &
sleep 5
argocd login localhost:8080 --username admin --password "$PASSWORD" --insecure

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

kubectl apply -f local-cluster/core-services.yaml

# Install CA Certificate secret so Cert Manager can issue certificates using our CA

kubectl apply -f ${config_dir}/local-cluster/core/cert-manager/namespace.yaml
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

cat <<EOF > local-cluster/config/cluster-params.yaml
dnsSuffix: ${local_dns}
storageClass: standard
EOF
git add local-cluster/config/cluster-params.yaml
if [[ `git status --porcelain` ]]; then
  git commit -m "update cluster params with dns suffix"
  git pull
  git push
fi

# Force a refresh of the Argo CD repo server to pick up the latest git changes
echo "Refreshing Argo CD repository cache..."
kubectl rollout restart deployment argocd-repo-server -n argocd
kubectl wait --for=condition=Available -n argocd deployment/argocd-repo-server --timeout=2m

# Apply the ingress appset
kubectl apply -f local-cluster/ingress-appset.yaml

# Wait for the ApplicationSet controller to create the Application
sleep 5
echo "Waiting for Argo CD ApplicationSet to generate the ingress-nginx application..."
kubectl wait --for=condition=ResourcesUpToDate=True applicationset/ingress-appset -n argocd --timeout=2m
echo "ApplicationSet 'ingress-appset' is up to date."

# Wait for the ingress-nginx application to be healthy
sleep 5
echo "Waiting for the ingress-nginx application to become healthy..."
kubectl wait --for=jsonpath='{.status.health.status}'=Healthy application/ingress-nginx -n argocd --timeout=5m
echo "Application 'ingress-nginx' is healthy."

sleep 5
echo "Waiting for the ingress-nginx application to become healthy..."
kubectl wait --for=jsonpath='{.status.health.status}'=Healthy application/ingress-nginx -n argocd --timeout=5m
echo "Application 'ingress-nginx' is healthy."

sleep 5
export CLUSTER_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')

# Now that we have the cluster IP, update the params file and push to git again
cat <<EOF > local-cluster/config/cluster-params.yaml
dnsSuffix: ${local_dns}
clusterIP: ${CLUSTER_IP}
storageClass: standard
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
kubectl apply -f local-cluster/core-appset.yaml

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

sleep 5
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

secrets.sh $debug_str --tls-skip --secrets $PWD/resources/secrets

kubectl rollout restart deployment -n external-secrets external-secrets

kubectl apply -f local-cluster/addons.yaml
kubectl apply -f local-cluster/apps.yaml
kubectl apply -f local-cluster/apps-appset.yaml
