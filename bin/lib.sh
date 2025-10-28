#!/usr/bin/env bash

# Library of functions
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@tesco.com)

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

function add_to_path() {
    new_path="${1:-}"
    if [ -z "${new_path}" ]; then
        echo "no path provided"
        return 1
    fi

    if { $SCRIPT_DIR/show-path.sh | grep -q "^${new_path}$"; }; then
        return
    fi
    PATH="${new_path}:$PATH"
}

function local_or_global() {
    local_file="${1:-}"
    if [ -e "${local_file}" ]; then
        echo "./${local_file}"
    else 
        echo "${config_dir}/${local_file}"
    fi
}
