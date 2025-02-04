#!/usr/bin/env bash

# Copyright (c) 2023 Microsoft Corporation
#
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o nounset
set -o pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${tests_dir}/common.bash"

AZ_RG="${AZ_RG:-kataCI}"

function _print_cluster_name() {
    test_type="${1:-k8s}"

    short_sha="$(git rev-parse --short=12 HEAD)"
    echo "${test_type}-${GH_PR_NUMBER}-${short_sha}-${KATA_HYPERVISOR}-${KATA_HOST_OS}-amd64"
}

function install_azure_cli() {
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    # The aks-preview extension is required while the Mariner Kata host is in preview.
    az extension add --name aks-preview
}

function login_azure() {
    az login \
        --service-principal \
        -u "${AZ_APPID}" \
        -p "${AZ_PASSWORD}" \
        --tenant "${AZ_TENANT_ID}"
}

function create_cluster() {
    test_type="${1:-k8s}"

    # First, ensure that the cluster didn't fail to get cleaned up from a previous run.
    delete_cluster "${test_type}" || true

    az aks create \
        -g "${AZ_RG}" \
        -n "$(_print_cluster_name ${test_type})" \
        -s "Standard_D4s_v5" \
        --node-count 1 \
        --generate-ssh-keys \
        $([ "${KATA_HOST_OS}" = "cbl-mariner" ] && echo "--os-sku AzureLinux --workload-runtime KataMshvVmIsolation")
}

function install_bats() {
    # Installing bats from the lunar repo.
    # This installs newer version of the bats which supports setup_file and teardown_file functions.
    # These functions are helpful when adding new tests that require one time setup.

    sudo apt install -y software-properties-common
    sudo add-apt-repository 'deb http://archive.ubuntu.com/ubuntu/ lunar universe'
    sudo apt install -y bats
    sudo add-apt-repository --remove 'deb http://archive.ubuntu.com/ubuntu/ lunar universe'
}

function install_kubectl() {
    sudo az aks install-cli
}

function get_cluster_credentials() {
    test_type="${1:-k8s}"

    az aks get-credentials \
        -g "${AZ_RG}" \
        -n "$(_print_cluster_name ${test_type})"
}

function delete_cluster() {
    test_type="${1:-k8s}"

    az aks delete \
        -g "${AZ_RG}" \
        -n "$(_print_cluster_name ${test_type})" \
        --yes
}

function get_nodes_and_pods_info() {
    kubectl debug $(kubectl get nodes -o name) -it --image=quay.io/kata-containers/kata-debug:latest || true
    kubectl get pods -o name | grep node-debugger | xargs kubectl delete || true
}
