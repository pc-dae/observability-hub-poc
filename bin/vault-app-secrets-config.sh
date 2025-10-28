#!/usr/bin/env bash

# Utility for configuring vault kv secrets per app
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] " >&2
    echo "This script will configure vault secrets per app" >&2
}

function args() {

  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  tls_skip=""
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--tls-skip") tls_skip="-tls-skip-verify";;
          "--debug") set -x;;
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

export VAULT_ADDR="https://vault.${local_dns}"
export VAULT_TOKEN="$(jq -r '.root_token' resources/.vault-init.json)"

set +e

VAULT_NAMESPACE=${VAULT_NAMESPACE:-"247networksoftware1"}
KUBE_HOST=$(kubectl config view --raw --minify | grep "server:" | awk '{print $NF}')
KUBE_CA_CERT=$(kubectl config view --raw --minify | grep "certificate-authority-data:" | awk '{print $NF}' | base64 -d)
TOKEN_REVIEW_JWT=$(kubectl get serviceaccount secret-consumer -n ${nameSpace} -o jsonpath='{.secrets[0].name}' | xargs -n 1 kubectl get secret -n naas -o jsonpath='{.data.token}' | base64 -d)

vault write auth/kubernetes/config \
    token_reviewer_jwt="$TOKEN_REVIEW_JWT" \
    kubernetes_host="$KUBE_HOST" \
    kubernetes_ca_cert="$KUBE_CA_CERT"

echo "Creating Vault role for the service account..."
vault write auth/kubernetes/role/${nameSpace}-${appName}-role \
    bound_service_account_names="secret-consumer" \
    bound_service_account_namespaces="${nameSpace}" \
    policies="application-reader" \
    ttl="1h"

