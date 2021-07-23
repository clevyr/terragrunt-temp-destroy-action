#!/usr/bin/env bash

set -euo pipefail

# Set up some variables so we can reference the GitHub Action context
__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__file="${__dir}/$(basename "${BASH_SOURCE[0]}")"
__base="$(basename ${__file} .sh)"

_log() {
    local IFS=$' \n\t'
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2;
}
cluster_info() {
    gcloud container --project "$host_project" clusters list --format json \
        | jq -r --arg 'key' "$1" '.[][$key]'
}

set_deployment_status() {
    if [[ -n "${deployment_id:-}" ]]; then
        local state="$1" \
            environment_url="${2:-}"
        gh api --silent -X POST "/repos/:owner/:repo/deployments/$deployment_id/statuses" \
            -H 'Accept: application/vnd.github.ant-man-preview+json' \
            -H 'Accept: application/vnd.github.flash-preview+json' \
            -F "state=$state" \
            -F "log_url=https://github.com/$GITHUB_REPOSITORY/commit/$GITHUB_SHA/checks" \
            -F 'auto_inactive=true'
    fi
}

export IFS=$'\n\t'

# Set helm url based on default, or use provided HELM_URL variable
helm_url="${HELM_URL:-https://helm.clevyr.cloud}"
host_project="${HOST_PROJECT:-momma-motus}"
# Set the project id based on the key file provided, or use the provided project id
project_id="${GCLOUD_GKE_PROJECT:-$(jq -r .project_id <<< "$GCLOUD_KEY_FILE")}"
region="us-central1"

_log "SHA: "$GITHUB_SHA
_log "Ref: "$GITHUB_REF
_log Verify this is a PR
type=$(echo $GITHUB_REF | awk -F/ '{print $1}')
if [ $type=="pull" ]; then
    prNum=$(echo $GITHUB_REF | awk -F/ '{print $3}')
else
    prNum=$(gh pr view --json number --jq .number)
    if [ ! $? -eq 0 ]; then
        _log "We're not operating on a pull request! Aborting."
        exit 1
    fi
fi
environment="pr"$prNum

_log Verify tempbuilds folder exists
if [ ! -d deployment/tempbuilds ]; then
    _log tempbuilds folder not found! Aborting.
    exit 1
fi

_log Activate gcloud auth
gcloud auth activate-service-account --key-file - <<< "$GCLOUD_KEY_FILE"
cluster_name="${GCLOUD_CLUSTER_NAME:-$(cluster_info name)}"
docker_repo="${REPO_URL:-us.gcr.io/$project_id}"
echo "$GCLOUD_KEY_FILE" > /tmp/serviceAccount.json
export GOOGLE_APPLICATION_CREDENTIALS=/tmp/serviceAccount.json

_log Select Kubernetes cluster
gcloud container clusters get-credentials  \
    "$cluster_name" \
    --region "$region" \
    --project "$host_project"

_log Verify the target namespace exists
appName=$(< deployment/application_name)
if ! kubectl get namespace $appName-pr$prNum ; then
    _log Target namespace does not exist, exiting.
    exit 0
fi

_log Starting Terragrunt and yq install...
brew install terragrunt yq --ignore-dependencies 2>&1 &
tg_install_pid="$!"

_log Add custom helm repo
helm repo add clevyr "$helm_url"
helm repo update

_log Renaming folder
cd deployment
mv tempbuilds $environment

_log Wait for Terragrunt to finish installing...
wait "$tg_install_pid"

_log Initializing Terragrunt
cd setup
terragrunt init
cd ../$environment
terragrunt init
_log Running Terragrunt destroy
terragrunt destroy -auto-approve
_log Destruction complete
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    # Set the deployment status
    deployment_id="$(gh api -X GET "/repos/:owner/:repo/deployments" | jq --arg environment "$environment" '.[] | select(.environment==$environment) | .id' | head -n 1)"
    set_deployment_status inactive
fi
