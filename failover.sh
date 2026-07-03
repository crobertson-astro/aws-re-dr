#!/bin/bash
set -euo pipefail

kubectl config use-context failover
echo "Scaling up failover deployments..."
kubectl scale deployment --all --replicas=1

kubectl config use-context primary
echo "Scaling down primary deployments..."
kubectl scale deployment --all --replicas=0
