#!/bin/sh
# Requirements for this script:
#  1. Must be run from inside a kubernetes cluster with ServiceAccount
#     credentials mounted in the default location
#  2. curl and jq are installed inside the container.
#
# Script does the following actions:
#  1. Create an image-puller daemonset to fetch the user image on all nodes
#  2. Wait until the images are present in all the nodes
#  3. Kill the image-puller daemonset and exit
#
# All inputs are passed in as environment variables
#  1. DAEMONSET_SPEC
#     A single line JSON of the image-puller daemonset to create
#  2. KUBERNETES_SERVICE_HOST, KUBERNETES_SERVICE_PORT
#     The hostname and port to use for talking to the k8s API.
#     When running in cluster, this is automatically set by Kubernetes
#  3. IMAGE
#     Full name of user image
#  4. CURL_EXTRA_OPTIONS
#     Extra commandline options to pass to curl
set -euo pipefail

# Allow setting additional curl options
CURL_EXTRA_OPTIONS=${CURL_EXTRA_OPTIONS:-}
CURL_OPTIONS="--fail --silent --show-error ${CURL_EXTRA_OPTIONS}"

pulling_complete() {
    # Return 0 if all nodes have ${IMAGE} present in them, 1 otherwise

    # Grab definitions of all nodes in the cluster
    NODES=$(curl \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
                --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
                -X GET \
                ${CURL_OPTIONS} \
                https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/api/v1/nodes
         );

    # Find out how many nodes we have in total
    TOTAL_NODES=$(echo ${NODES} | jq -r '.items | length')

    # Find out how many nodes report having the image we care about
    COMPLETE_NODES=$(echo ${NODES} | jq -f nodes_with_image.jq --arg image ${IMAGE}| jq -r length)

    echo "${COMPLETE_NODES} of ${TOTAL_NODES} complete"
    if [[ ${COMPLETE_NODES} -eq ${TOTAL_NODES} ]]; then
        return 0;
    else
        return 1;
    fi
}

if pulling_complete; then
    echo "All images already present on all nodes!"
    exit 0
fi

# Create a daemonset and capture the output from the k8s API
# When successfully created, the API output is a JSON object representing the complete spec
echo "Creating Daemonset..."
DAEMONSET=$(curl \
    -H "Content-Type: application/json"  \
    -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt  \
    -X POST \
    ${CURL_OPTIONS} \
    https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/apis/extensions/v1beta1/namespaces/${NAMESPACE}/daemonsets \
    -d "${DAEMONSET_SPEC}"
)

# Find the generated name of the daemonset from the API response
DAEMONSET_NAME=$(echo ${DAEMONSET} | jq -r .metadata.name)

# Loop until all nodes have the image we want
echo "Waiting for all nodes to pull images..."
while ! pulling_complete; do
    sleep 2;
done
echo "All nodes have the images we need!"

# Delete the daemonset after pulling is complete
# We set propagationPolicy to "Foreground" to have the call wait until all the pods from daemonset disappear
echo "Deleting daemonset"
curl \
    -H "Content-Type: application/json"  \
    -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt  \
    ${CURL_OPTIONS} \
    -X DELETE \
    https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/apis/extensions/v1beta1/namespaces/${NAMESPACE}/daemonsets/${DAEMONSET_NAME} \
    -d '{"apiVersion": "v1", "kind": "DeleteOptions", "propagationPolicy": "Foreground"}'

