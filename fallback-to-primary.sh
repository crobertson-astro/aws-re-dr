#!/bin/bash
set -euo pipefail

kubectl config use-context primary
echo "Scaling up primary deployments..."
kubectl scale deployment --all --replicas=1

kubectl config use-context failover
echo "Scaling down failover deployments..."
# Drain the failover node to prevent new pods from being scheduled there, then scale down.
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl drain $NODE_NAME
kubectl scale deployment --all --replicas=0

# reset context to primary so that the user can continue working with the primary cluster
kubectl config use-context primary
