# EasyCRUD on AWS EKS: Terraform + Jenkins DevSecOps pipeline

Production-style deployment of the EasyCRUD app (React frontend, Spring Boot backend, MariaDB) on AWS.

```
Developer -> GitHub -> Jenkins controller (private EC2) -> Jenkins agent (private EC2)
                                                             | gitleaks, tests, SonarQube, trivy
                                                             v
                                                      ECR (immutable tags, scan on push)
                                                             | kubectl apply (namespace-scoped role)
Internet -> ALB (public subnets) -> EKS pods (private subnets) -> RDS MariaDB (database subnets, no public access)
```

Everything is created from this repo. Infrastructure is applied with Terraform by an engineer; Jenkins only builds, scans, pushes and deploys.

---

## 1. What gets created (default settings)

| Resource | Count | Notes |
|---|---|---|
| **EC2: Jenkins controller** | 1 | t3.medium, private subnet, no SSH, runs 0 builds |
| **EC2: Jenkins agent** | 1 | t3.large, private subnet, Docker, Maven, Trivy, Gitleaks, kubectl |
| **EC2: SonarQube** | 1 | t3.medium, optional (`create_sonarqube = false` to skip) |
| **EC2: EKS worker nodes** | 2 | managed node group, min 2 / max 4, private subnets (never create these by hand) |
| **Total EC2 instances** | **5** | 3 you can log into via SSM + 2 managed by EKS |
| VPC | 1 | 2 AZs |
| Subnets | 6 | 2 public (ALB, NAT), 2 private (nodes, CI), 2 database |
| NAT gateway + Elastic IP | 1 + 1 | `single_nat_gateway = false` gives one per AZ |
| Internet gateway | 1 | |
| EKS cluster | 1 | KMS-encrypted secrets, audit logs, private + restricted public API |
| RDS MariaDB | 1 | Multi-AZ, encrypted, private, password managed by Secrets Manager |
| Secrets Manager secret | 1 | created by RDS |
| ECR repositories | 2 | `easycrud/backend`, `easycrud/frontend` |
| Application Load Balancer | 1 | created by the AWS Load Balancer Controller from `k8s/30-ingress.yaml` |
| IAM roles | 7 | see section 9 |
| Security groups | 6 | rds, controller, agent, sonarqube, eks cluster, eks nodes |
| S3 bucket | 1 | Terraform state (created by `scripts/bootstrap-state.sh`) |
| CloudWatch log groups | 2 | EKS control plane, VPC flow logs |

Cost drivers: NAT gateway, EKS control plane, Multi-AZ RDS, the 5 EC2s. For non-prod use the cheaper profile in `terraform/terraform.tfvars.example`.

---

## 2. Prerequisites

Workstation (Linux/macOS/WSL): `aws` CLI v2, `terraform` >= 1.10, `kubectl`, `helm`, `git`, and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

```bash
aws sso login            # or: aws configure --profile prod  (never use the root user; enable MFA)
aws sts get-caller-identity
```

The identity running Terraform needs permission to create the resources above (EC2, VPC, EKS, RDS, ECR, IAM roles, KMS, S3, CloudWatch). It becomes EKS cluster admin. See section 9 for how to narrow it.

Optional pre-apply scans:

```bash
pip install checkov
checkov -d terraform --framework terraform
trivy config terraform
```

---

## 3. Clean up the old version first (if you ever ran it)

The previous version of this repo used a hard-coded database password, a publicly reachable database and static AWS keys. Before going live:

1. If the old stack was ever applied to a real account, run `terraform destroy` from the old Jenkins workspace (state lived there), or delete the old RDS instance, EKS cluster and node group by hand.
2. Rotate everything that was exposed: the old DB password, the AWS access keys behind the old `aws-cred` credential, and the Docker Hub token. Delete the unused IAM user keys.
3. The old password and RDS hostname are still in Git history. Rewrite history (`git filter-repo`) or at least treat them as leaked. Gitleaks in the pipeline scans history, so the first run fails until history is cleaned or a baseline is created (`gitleaks detect --baseline-path`).

---

## 4. Step 1: Terraform state bucket (once)

```bash
export REGION=us-east-1
export STATE_BUCKET=<company>-tfstate-$(aws sts get-caller-identity --query Account --output text)
./scripts/bootstrap-state.sh "$STATE_BUCKET" "$REGION"

cd terraform
cp backend.hcl.example backend.hcl            # put the bucket name and region in
cp terraform.tfvars.example terraform.tfvars  # put YOUR public IP in api_allowed_cidrs
curl -s https://checkip.amazonaws.com         # your current IP; use <ip>/32
```

---

## 5. Step 2: Build the infrastructure

```bash
cd terraform
terraform init -backend-config=backend.hcl
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform show tfplan | less          # read it. Never apply a plan you have not read.
terraform apply tfplan                # EKS + RDS take roughly 15-25 minutes
terraform output
```

Then install the cluster add-ons (namespace, ALB controller, metrics-server):

```bash
cd ..
./scripts/install-addons.sh
kubectl get nodes                     # 2 nodes Ready
kubectl get pods -n kube-system       # aws-load-balancer-controller 2/2 Running
```

---

## 6. Step 3: Configure Jenkins (controller)

Jenkins has no public IP. Reach it through an SSM port-forward:

```bash
CONTROLLER=$(terraform -chdir=terraform output -raw jenkins_controller_instance_id)

# Initial admin password
aws ssm start-session --target "$CONTROLLER"
sudo cat /var/lib/jenkins/secrets/initialAdminPassword       # then: exit

# Open the UI at http://localhost:8080 (keep this running in a terminal)
aws ssm start-session --target "$CONTROLLER" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```

If the first-boot script did not finish, check `sudo tail -n 50 /var/log/cloud-init-output.log` on the instance.

In the Jenkins UI:

1. Install suggested plugins, plus **SonarQube Scanner** and **Pipeline: Stage View**.
2. Create a named admin user (not `admin/initial password`).
3. **Manage Jenkins -> Security**: use "Jenkins' own user database", disable sign-up and anonymous access, use Matrix-based or Role-based authorization.
4. **Manage Jenkins -> Nodes -> Built-In Node -> Configure**: set **Number of executors = 0** so nothing builds on the controller.
5. **Manage Jenkins -> System -> Jenkins URL**: `http://<jenkins_controller_private_ip>:8080/` (value from `terraform output`). Agents use this address.

### Connect the agent

1. **Manage Jenkins -> Nodes -> New Node**: name `build-agent-1`, type Permanent Agent.
2. Remote root directory `/home/jenkins-agent`, **Labels `build-agent`**, Usage "Only build jobs with label expressions matching this node".
3. Launch method: **Launch agent by connecting it to the controller**, tick **Use WebSocket**. Save and copy the secret shown on the node page.
4. On the agent host:

```bash
AGENT=$(terraform -chdir=terraform output -raw jenkins_agent_instance_id)
aws ssm start-session --target "$AGENT"
sudo setup-jenkins-agent http://<jenkins_controller_private_ip>:8080 <SECRET> build-agent-1
```

The node turns green in Jenkins. Verify the tools on the agent:

```bash
docker --version && mvn -v && trivy --version && gitleaks version && kubectl version --client && aws --version
```

Verify the IAM scoping from the agent (this is the point of least privilege):

```bash
aws eks update-kubeconfig --region us-east-1 --name easycrud-prod
kubectl auth can-i create deployments -n easycrud         # yes
kubectl auth can-i get secrets -n kube-system             # no
kubectl auth can-i create namespaces                      # no
```

---

## 7. Step 4: SonarQube (skip if `create_sonarqube = false`; also delete the two Sonar stages in the Jenkinsfile)

```bash
SONAR=$(terraform -chdir=terraform output -raw sonarqube_instance_id)
aws ssm start-session --target "$SONAR" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9000"],"localPortNumber":["9000"]}'
```

Open `http://localhost:9000` (allow a minute or two to start). Log in with `admin` / `admin` and change the password immediately.

1. **My Account -> Security -> Generate token** (type: user token). Copy it.
2. Jenkins -> **Manage Jenkins -> Credentials -> Global -> Add**: kind *Secret text*, ID `sonar-token`.
3. Jenkins -> **Manage Jenkins -> System -> SonarQube servers -> Add**: name **`sonarqube`** (the Jenkinsfile uses this exact name), URL `http://<sonarqube_private_ip>:9000`, token `sonar-token`.
4. SonarQube -> **Administration -> Configuration -> Webhooks -> Create**: URL `http://<jenkins_controller_private_ip>:8080/sonarqube-webhook/`. Without this the quality gate waits until it times out.

---

## 8. Step 5: Create the pipeline job and deploy

1. **New Item** -> name `easycrud-eks-deployment` -> **Pipeline**.
2. Pipeline -> Definition **Pipeline script from SCM** -> Git -> your repo URL, branch `*/main`, script path `Jenkinsfile`. (Private repo: add a read-only deploy key or token as a Jenkins credential.)
3. Build Triggers -> **Poll SCM** `H/5 * * * *`. Jenkins is private, so GitHub webhooks cannot reach it. To use webhooks, put an internet-facing ALB in front of Jenkins restricted to GitHub's webhook IP ranges.
4. Optional: set `APPROVERS` in the Jenkinsfile to the Jenkins user IDs allowed to approve production deploys.
5. **Build Now.** Stages: checkout -> gitleaks -> unit tests + SonarQube -> quality gate -> trivy fs -> trivy config -> build -> trivy image -> push to ECR -> **manual approval** -> deploy -> rollout check.

Verify:

```bash
kubectl get pods,svc,ingress,hpa -n easycrud
kubectl get ingress easycrud -n easycrud -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
curl -i http://<alb-dns-name>/healthz          # frontend: 200
curl -i http://<alb-dns-name>/api/users        # backend through the ALB: 200 []
kubectl logs deploy/backend -n easycrud --tail=50
```

Rollback (the pipeline also does this automatically if the rollout fails):

```bash
kubectl rollout history deployment/backend -n easycrud
kubectl rollout undo deployment/backend -n easycrud
```

---

## 9. IAM and least privilege

| Identity | Can do | Cannot do |
|---|---|---|
| Engineer / Terraform role (human, SSO + MFA) | Create the infrastructure; EKS cluster admin | Should not be used by Jenkins |
| `easycrud-prod-jenkins-controller` | SSM session only | Everything else |
| `easycrud-prod-jenkins-agent` | ECR login; push/pull to the 2 repos; `eks:DescribeCluster` on this cluster; describe the one DB instance; read the one DB secret; edit workloads in namespace `easycrud` only (EKS access entry) | Create namespaces, touch other namespaces, change infrastructure, use other secrets |
| `easycrud-prod-sonarqube` | SSM session only | Everything else |
| EKS node role | Standard managed policies (worker, CNI, ECR read, SSM) | |
| `easycrud-prod-aws-lb-controller` (IRSA) | Official ALB controller policy, only for its service account | |
| Pods | No service account token mounted, no AWS permissions | |

Narrowing the Terraform deployer: a fully minimal policy for `terraform apply` cannot be written reliably up front. Practical approach: run the first apply with a short-lived, MFA-protected role limited to the services above, then generate a least-privilege policy from CloudTrail with IAM Access Analyzer (`aws accessanalyzer start-policy-generation`) and swap it in. Attach a permissions boundary to that role so it can only create roles that carry the same boundary.

---

## 10. HTTPS and DNS

1. Request an ACM certificate for your domain (DNS validation).
2. In `k8s/30-ingress.yaml` replace the `listen-ports` annotation with the HTTPS block from the comment at the top of the file (certificate ARN, `ssl-redirect`).
3. Run the pipeline, then create a Route 53 alias record pointing your domain to the ALB.

---

## 11. Day-2 operations

Change infrastructure: edit `terraform/`, then `terraform plan -out=tfplan` -> review -> `terraform apply tfplan`.

Destroy everything (the DB has deletion protection on by default):

```bash
kubectl delete ingress easycrud -n easycrud        # lets the controller remove the ALB first
cd terraform
terraform apply -var="db_deletion_protection=false" -target=aws_db_instance.this   # then:
terraform destroy
```

Not included, add before real production traffic:

- Backups of the Jenkins home volume (AWS Backup or DLM snapshots) and of the SonarQube host.
- Patching for the three EC2 hosts (SSM Patch Manager). Terraform ignores AMI changes on purpose so hosts are never replaced by accident.
- Alarms (CloudWatch/SNS) for node, RDS and ALB health; GuardDuty; CloudTrail; AWS Budgets.
- Database schema migrations with Flyway or Liquibase (`ddl-auto=update` is convenient, not production-grade) and a dedicated least-privilege DB user instead of the RDS master user.
- TLS verification to RDS (`sslMode=verify-full` with the RDS CA bundle). The app uses `sslMode=trust` (encrypted, certificate not verified).
- Jenkins over HTTPS (internal ALB with an ACM certificate) and External Secrets Operator instead of the pipeline-created Kubernetes Secret.
- Image signing (cosign) and a DAST stage (OWASP ZAP) against a staging URL.

---

## 12. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Node stays offline | Jenkins URL not set to the private IP, or the controller SG lacks the agent rule. `journalctl -u jenkins-agent -n 50` on the agent |
| Quality gate times out | SonarQube webhook missing or wrong URL (section 7, step 4) |
| `ecr: tag invalid, immutable` | Re-pushing the same tag. Tags are `<build>-<sha>`; start a new build |
| Pods `CreateContainerConfigError` | Secret `easycrud-db` missing: the deploy stage failed before creating it |
| Pods blocked by policy / `forbidden: violates PodSecurity` | A manifest change removed `runAsNonRoot`, `seccompProfile` or `capabilities.drop` |
| ALB has no targets | LB controller not running, or NetworkPolicy CIDR does not match your VPC CIDR (`k8s/40-networkpolicy.yaml`) |
| `kubectl` times out from your laptop | Your public IP changed; update `api_allowed_cidrs` and re-apply |
| Unit tests fail in CI | They use in-memory H2 (`backend/src/test/resources`), not the real DB |
