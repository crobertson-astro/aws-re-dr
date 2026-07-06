#!/bin/bash
set -euo pipefail

kubectl config use-context failover
echo "Scaling up failover deployments..."
kubectl scale deployment --all --replicas=1

kubectl config use-context primary
echo "Scaling down primary deployments..."
# In a real failover scenario, failover will be unavailable so these cmds will likely fail.
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl drain $NODE_NAME
kubectl scale deployment --all --replicas=0

# reset context to failover so that the user can continue working with the failover cluster
kubectl config use-context failover
