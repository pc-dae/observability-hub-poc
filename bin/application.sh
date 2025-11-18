#!/usr/bin/env bash

# Utility to deploy an ArgoCD Application and wait for it to be healthy
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug]" >&2
    echo "This script will deploy an ArgoCD Application and wait for it to be healthy" >&2
    echo "  --debug: emmit debugging information" >&2
}

function args()
{
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x; debug_str="--debug";;
               "-h") usage; exit;;
           "--help") usage; exit;;
               "-?") usage; exit;;
          "--file") (( arg_index+=1 ));application_file=${arg_list[${arg_index}]};;
        *) if [ "${arg_list[${arg_index}]:0:2}" == "--" ];then
               echo "invalid argument: ${arg_list[${arg_index}]}" >&2
               usage; exit
           fi;
           break;;
    esac
    (( arg_index+=1 ))
  done
  if [ -z "$application_file" ]; then
    echo "The --file argument is required" >&2
    usage; exit 1
  fi
}

args "$@"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/envs.sh

name=$(yq '.metadata.name' $application_file)
kubectl apply -f $application_file

# Wait for the $name application to be healthy
sleep 5
echo "Waiting for the $name application to become healthy..."
kubectl wait --for=jsonpath='{.status.health.status}'=Healthy application/$name -n argocd --timeout=5m
return_code=$?
if [ $return_code -ne 0 ]; then
  echo "Application '$name' is not healthy" >&2
  exit $return_code
fi
echo "Application '$name' is healthy."
