#!/usr/bin/env bash

# Utility for creating secrets in Vault
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--tls-skip] --secrets <secrets file>" >&2
    echo "This script will create secrets in Vault" >&2
    echo " The --secrets option should reference a bash script which sets the github secrets" >&2
    echo "use the --tls-skip option to load data prior to ingress certificate setup" >&2
}

function args() {
  tls_skip=""
  script_tls_skip=""

  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  debug_str=""
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--secrets") (( arg_index+=1 ));secrets_file=${arg_list[${arg_index}]};;
          "--debug") set -x; debug_str="--debug";;
          "--tls-skip") tls_skip="-tls-skip-verify"; script_tls_skip="--tls-skip";;
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

source ${secrets_file}

vault kv put ${tls_skip} -mount=secrets github-repo-read-credentials username=token password=${GITHUB_TOKEN_READ}

vault kv put ${tls_skip} -mount=secrets github-repo-write-credentials username=token password=${GITHUB_TOKEN_WRITE}

vault kv put ${tls_skip} -mount=secrets github-repo-write-token token=${GITHUB_TOKEN_WRITE}

RECEIVER_TOKEN=$(head -c 12 /dev/urandom | shasum | cut -d ' ' -f1)
vault kv put ${tls_skip} -mount=secrets receiver-token token=${RECEIVER_TOKEN}
