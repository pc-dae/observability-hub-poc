#!/usr/bin/env bash

# Utility for initializing vault
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] " >&2
    echo "This script will initialize vault" >&2
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

if [ "$(vault status --format=json $tls_skip | jq -r '.initialized')" == "true" ]; then
  echo "Vault already initialized"
  exit 0
fi

vault operator init $tls_skip -format=json > resources/.vault-init.json
