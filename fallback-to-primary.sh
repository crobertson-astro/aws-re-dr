#!/bin/bash
set -euo pipefail

kubectl config use-context primary
echo "Scaling up primary deployments..."
kubectl scale deployment --all --replicas=1

kubectl config use-context failover
echo "Scaling down failover deployments..."
kubectl scale deployment --all --replicas=0
