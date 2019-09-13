#!/bin/sh

set -e

echo_info() {
    printf "\\033[0;34m%s\\033[0;0m\\n" "$1"
}

echo_warn() {
    printf "\\033[0;33m%s\\033[0;0m\\n" "$1"
}


## Sanity check
##

if [ -z "$CIRCLE_GPG_KEY" ] ||
       [ -z "$CIRCLE_GPG_OWNERTRUST" ] ||
       [ -z "$GCP_KEY_FILE" ] ||
       [ -z "$GCP_ACCOUNT_ID" ] ||
       [ -z "$GCP_ZONE" ]; then
    echo_warn "Deploy credentials not present, skipping deploy."
    exit 0
fi


## GPG
##

GPGFILE=$(mktemp)
trap 'rm -f $GPGFILE' 0 1 2 3 6 14 15
echo "$CIRCLE_GPG_KEY" | base64 -d | gunzip > "$GPGFILE"
gpg --import "$GPGFILE"
printf "%s\\n" "$CIRCLE_GPG_OWNERTRUST" | gpg --import-ownertrust


## GCP
##

GCPFILE=$(mktemp)
trap 'rm -f $GCPFILE' 0 1 2 3 6 14 15
echo "$GCP_KEY_FILE" | base64 -d > "$GCPFILE"

gcloud auth activate-service-account --key-file="$GCPFILE"
gcloud config set project "$GCP_ACCOUNT_ID"
gcloud config set compute/zone ${GCP_ZONE}
gcloud container clusters get-credentials ${GCP_CLUSTER_DEVELOPMENT}

if [ "$DEPLOY" = "watcher" ]; then
    kubectl set image statefulset watcher-samrong watcher=omisego/watcher:latest
    while true; do if [ "$(kubectl get pods watcher-samrong-0 -o jsonpath=\"{.status.phase}\" | grep Running)" ]; then break; fi; done
else
    kubectl set image statefulset childchain-samrong childchain=omisego/child_chain:latest
    while true; do if [ "$(kubectl get pods childchain-samrong-0 -o jsonpath=\"{.status.phase}\" | grep Running)" ]; then break; fi; done
fi;