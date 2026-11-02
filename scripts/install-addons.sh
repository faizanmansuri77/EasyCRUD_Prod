#!/usr/bin/env bash
# Run ONCE by the cluster admin (the identity that ran `terraform apply`), from your workstation.
# Needs: aws, kubectl, helm, terraform (already initialised with backend.hcl).
set -euo pipefail
cd "$(dirname "$0")/.."

TF="terraform -chdir=terraform output -raw"
REGION="$($TF region)"
CLUSTER="$($TF cluster_name)"
VPC_ID="$($TF vpc_id)"
LB_ROLE_ARN="$($TF lb_controller_role_arn)"

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

# 1) Namespace with Pod Security "restricted" (Jenkins is not allowed to create namespaces)
kubectl apply -f k8s/00-namespace.yaml

# 2) AWS Load Balancer Controller (creates the ALB from our Ingress)
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set replicaCount=2 \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${LB_ROLE_ARN}"

# 3) metrics-server (needed by the HorizontalPodAutoscalers)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=300s
echo "Add-ons installed."
