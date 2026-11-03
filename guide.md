# EasyCRUD on AWS EKS: deploy from scratch

Step-by-step runbook for the hardened repo (Terraform, Jenkins, SonarQube, EKS), run from an Ubuntu Server over SSH. Do the phases in order. Replace anything in \<angle brackets>. Region used: us-east-1.

## 0. Roadmap

| Phase | What you do | Time |
| --- | --- | --- |
| 1 | Install tools, log in to AWS | 15 min |
| 2 | Get the code, set your values | 10 min |
| 3 | Create the Terraform state bucket | 2 min |
| 4 | terraform apply (launches VPC, EKS, RDS, ECR and 3 EC2s) | 25 min |
| 5 | Verify the EC2 servers | 10 min |
| 6 | Install cluster add-ons | 5 min |
| 7 | Configure the Jenkins controller | 20 min |
| 8 | Connect the Jenkins agent | 10 min |
| 9 | Configure SonarQube | 10 min |
| 10 | Create the pipeline job | 10 min |
| 11 | First deploy and test | 15 min |

EC2 servers at the end: jenkins-controller, jenkins-agent, sonarqube (3 you manage) plus 2 EKS worker nodes (managed by EKS) = 5. Terraform launches all of them. If you want to launch the three by hand in the console, see Appendix A.

## 1. Prepare your workstation

These steps assume Ubuntu Server 22.04 or 24.04 over SSH, with no desktop or browser. Start `tmux` first, so a dropped connection does not kill a 25-minute `terraform apply`. Because you run `kubectl` from this server, `api_allowed_cidrs` in phase 2 must be this server's public IP (`curl -s https://checkip.amazonaws.com`). No Ubuntu server yet? See Appendix B.

```bash
# Base packages
sudo apt-get update
sudo apt-get install -y unzip curl wget git jq gnupg lsb-release software-properties-common tmux

# AWS CLI v2 (x86_64; on an ARM server use awscli-exe-linux-aarch64.zip)
curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install

# Terraform (needs 1.10 or newer)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# kubectl and helm
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Session Manager plugin (shells and port-forwards to the private EC2s; ARM server: ubuntu_arm64)
curl 'https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb' -o ssm-plugin.deb
sudo dpkg -i ssm-plugin.deb
```

Log in to AWS. Never use the root user, and enable MFA on your own user. A server has no browser: the CLI prints a URL and a code, so open that URL on your laptop and type in the code.

```bash
aws configure sso --profile prod
aws sso login --profile prod --use-device-code
export AWS_PROFILE=prod
aws sts get-caller-identity
terraform -version && kubectl version --client && helm version && session-manager-plugin
```

## 2. Get the code and set your values

Unzip the hardened repo and push it to a NEW GitHub repository. Do not reuse the old repository, because its history contains the old database password.

```bash
unzip easycrud-eks-deployment-hardened.zip
cd easycrud-eks-deployment-by-jenkins
git init -b main
git add . && git commit -m 'Hardened deployment'
git remote add origin https://github.com/<you>/<new-repo>.git
git push -u origin main
```

Values to check before you continue:

| File | What to set |
| --- | --- |
| terraform/terraform.tfvars | Copy from terraform.tfvars.example. Set api\_allowed\_cidrs to your public IP, e.g. \["203.0.113.10/32"\]. Find it with: curl -s https://checkip.amazonaws.com |
| terraform/backend.hcl | Copy from backend.hcl.example (filled in during phase 3) |
| Jenkinsfile (environment block) | AWS\_REGION, CLUSTER\_NAME (easycrud-prod), DB\_INSTANCE\_ID (easycrud-prod-db). Change only if you changed project/environment/region in Terraform |
| k8s/40-networkpolicy.yaml | Only if you changed vpc\_cidr: update the two CIDRs |

If you want a different region, change it in terraform/variables.tf and in the Jenkinsfile (AWS\_REGION and AWS\_DEFAULT\_REGION), and pass it to the bootstrap script in phase 3.

For a cheaper non-production setup, uncomment the extra lines in terraform.tfvars.example (single-AZ database, 1 node, no SonarQube). If you skip SonarQube, also delete the two Sonar stages in the Jenkinsfile.

## 3. Create the Terraform state bucket (once)

```bash
export REGION=us-east-1
export STATE_BUCKET=<company>-tfstate-$(aws sts get-caller-identity --query Account --output text)
./scripts/bootstrap-state.sh "$STATE_BUCKET" "$REGION"

cd terraform
cp backend.hcl.example backend.hcl            # put the bucket name and region in
cp terraform.tfvars.example terraform.tfvars  # put your IP in api_allowed_cidrs
```

The bucket is versioned, encrypted, blocks public access and refuses non-TLS requests.

## 4. Terraform apply: this launches the infrastructure and the EC2s

```bash
terraform init -backend-config=backend.hcl
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform show tfplan | less
terraform apply tfplan
terraform output
```

Read the plan before applying. Apply takes about 15 to 25 minutes (EKS and RDS are the slow parts).

If plan rejects a version, list the valid ones and set it in terraform.tfvars:

```bash
aws eks describe-cluster-versions --query 'clusterVersions[].clusterVersion'
aws rds describe-db-engine-versions --engine mariadb --query 'DBEngineVersions[].EngineVersion'
```

What was launched: 1 VPC with 6 subnets, 1 NAT gateway, the EKS cluster plus 2 worker nodes, 1 Multi-AZ MariaDB database (password generated and kept in Secrets Manager), 2 ECR repositories, 3 EC2s (controller, agent, SonarQube) and the IAM roles and security groups for them.

## 5. Verify the EC2 servers

List them:

```bash
aws ec2 describe-instances --filters 'Name=tag:Project,Values=easycrud' 'Name=instance-state-name,Values=running' --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,InstanceType,PrivateIpAddress]' --output table
```

Expected: easycrud-prod-jenkins-controller, -jenkins-agent, -sonarqube, plus 2 EKS node instances. Check they are reachable through SSM (allow 3 to 5 minutes after launch). The 3 CI hosts should show Online:

```bash
aws ssm describe-instance-information --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output table
```

There is no SSH and no key pair. Open a shell with:

```bash
aws ssm start-session --target <instance-id>
```

Check each server once its install script has finished:

```bash
# Controller
cloud-init status --wait
sudo systemctl status jenkins --no-pager

# Agent
docker --version; mvn -v; trivy --version; gitleaks version; kubectl version --client; aws --version

# SonarQube (takes 1 to 2 minutes to start)
sudo docker ps
```

If something is missing, read the log: sudo tail -n 80 /var/log/cloud-init-output.log

Save the values you need later:

```bash
terraform output jenkins_controller_private_ip
terraform output sonarqube_private_ip
```

## 6. Install cluster add-ons

Run from the repo root, as the same identity that ran terraform apply (it is the cluster admin).

```bash
cd ..
./scripts/install-addons.sh
kubectl get nodes                  # 2 nodes Ready
kubectl get pods -n kube-system    # aws-load-balancer-controller Running
kubectl get ns easycrud --show-labels
```

This creates the easycrud namespace (Pod Security: restricted), installs the AWS Load Balancer Controller and metrics-server.

## 7. Configure the Jenkins controller

Jenkins has no public IP. Use SSM for everything.

```bash
CONTROLLER=$(terraform -chdir=terraform output -raw jenkins_controller_instance_id)

# 1) get the initial admin password
aws ssm start-session --target "$CONTROLLER"
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
exit

# 2) forward the UI to your laptop (keep this terminal open)
aws ssm start-session --target "$CONTROLLER" --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```

The port-forward runs on the Ubuntu server, so its localhost is the server's, not your laptop's. Keep it running in its own tmux window. On your laptop, open a second terminal and tunnel to the server:

```bash
ssh -L 8080:localhost:8080 <user>@<server-ip>
```

Then open http://localhost:8080 in your laptop's browser and:

1. Paste the initial password and choose Install suggested plugins.
2. Install two more plugins: SonarQube Scanner, Pipeline: Stage View. Restart when asked.
3. Create your own named admin user.
4. Manage Jenkins, Security: disable anonymous access and sign-up; use Matrix-based or Role-based authorization.
5. Manage Jenkins, Nodes, Built-In Node, Configure: set Number of executors to 0, so builds never run on the controller.
6. Manage Jenkins, System, Jenkins URL: set http://\<controller-private-ip>:8080/ (agents use this address).

## 8. Connect the Jenkins agent

In Jenkins: Manage Jenkins, Nodes, New Node.

- Name: build-agent-1, type Permanent Agent
- Remote root directory: /home/jenkins-agent
- Labels: build-agent (the Jenkinsfile requires this exact label)
- Usage: Only build jobs with label expressions matching this node
- Launch method: Launch agent by connecting it to the controller, with Use WebSocket ticked

Save, open the node page and copy the secret. Then on the agent host:

```bash
AGENT=$(terraform -chdir=terraform output -raw jenkins_agent_instance_id)
aws ssm start-session --target "$AGENT"
sudo setup-jenkins-agent http://<controller-private-ip>:8080 <SECRET> build-agent-1
```

The node turns green in Jenkins. Now prove the least-privilege setup from the agent:

```bash
aws eks update-kubeconfig --region us-east-1 --name easycrud-prod
kubectl auth can-i create deployments -n easycrud     # yes
kubectl auth can-i get secrets -n kube-system         # no
kubectl auth can-i create namespaces                  # no
```

If the node stays offline: check sudo journalctl -u jenkins-agent -n 50, and that the Jenkins URL in step 7.6 is the private IP.

## 9. Configure SonarQube

Skip this phase if you set create\_sonarqube = false.

```bash
SONAR=$(terraform -chdir=terraform output -raw sonarqube_instance_id)
aws ssm start-session --target "$SONAR" --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["9000"],"localPortNumber":["9000"]}'
```

Open the UI the same way: keep the port-forward running in a tmux window, run `ssh -L 9000:localhost:9000 <user>@<server-ip>` from your laptop, then browse http://localhost:9000. Log in with admin / admin and change the password straight away.

1. My Account, Security: generate a user token and copy it.
2. Jenkins, Manage Jenkins, Credentials, Global, Add: kind Secret text, ID sonar-token, paste the token.
3. Jenkins, Manage Jenkins, System, SonarQube servers, Add: name sonarqube (exactly this name), URL http://\<sonarqube-private-ip>:9000, server authentication token sonar-token.
4. SonarQube, Administration, Configuration, Webhooks, Create: URL http://\<controller-private-ip>:8080/sonarqube-webhook/ . Without this webhook the quality gate waits until it times out.

## 10. Create the pipeline job

1. Jenkins, New Item: name easycrud-eks-deployment, type Pipeline.
2. Pipeline definition: Pipeline script from SCM. SCM: Git. Repository URL: your new repo. Branch: \*/main. Script path: Jenkinsfile.
3. If the repo is private, add a read-only deploy key or token under Credentials and select it.
4. Build Triggers: Poll SCM with H/5 \* \* \* \* (Jenkins is private, so GitHub webhooks cannot reach it).
5. Optional: set APPROVERS in the Jenkinsfile to the Jenkins user IDs allowed to approve production deploys.
6. Save.

The only credential Jenkins stores is sonar-token. There are no AWS keys, no Docker Hub login and no DB password in Jenkins.

## 11. First deploy and test

Click Build Now. The pipeline runs these stages:

| Stage | Fails the build when |
| --- | --- |
| Gitleaks secret scan | a secret is found in the repo or its history |
| Unit tests + SonarQube | tests fail |
| Quality gate | SonarQube gate is red |
| Trivy fs / config | HIGH or CRITICAL issue in dependencies, Dockerfiles or k8s files |
| Build + Trivy image scan | HIGH or CRITICAL fixable vulnerability in an image |
| Push to ECR | ECR login or tag problem |
| Approval | you click Deploy (30 min timeout) |
| Deploy to EKS | manifest validation or rollout fails (then it rolls back) |

When it pauses at Approval, open the build and click Deploy. After success:

```bash
kubectl get pods,svc,ingress,hpa -n easycrud
ALB=$(kubectl get ingress easycrud -n easycrud -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $ALB
curl -i http://$ALB/healthz
curl -i http://$ALB/api/users
kubectl logs deploy/backend -n easycrud --tail=50
```

Expected: pods Running (2 of each), /healthz returns 200, /api/users returns 200 with \[\]. Open http://\<ALB> in a browser, register a student and confirm it appears. The ALB can take 2 to 3 minutes to become reachable the first time.

## 12. HTTPS and a domain

1. Request an ACM certificate for your domain in the same region (DNS validation).
2. In k8s/30-ingress.yaml, replace the listen-ports annotation with the HTTPS block shown in the comment at the top of the file (certificate-arn and ssl-redirect).
3. Commit and run the pipeline.
4. In Route 53, create an alias record from your domain to the ALB.

## 13. Day-2 commands

```bash
# redeploy: commit and push; Poll SCM starts the pipeline, or click Build Now

# roll back manually
kubectl rollout history deployment/backend -n easycrud
kubectl rollout undo deployment/backend -n easycrud

# change infrastructure
cd terraform && terraform plan -out=tfplan && terraform apply tfplan

# tear everything down (the DB has deletion protection)
kubectl delete ingress easycrud -n easycrud
cd terraform
terraform apply -var='db_deletion_protection=false' -target=aws_db_instance.this
terraform destroy
```

Also set up before real production traffic: Jenkins home backups (AWS Backup), OS patching with SSM Patch Manager, CloudWatch alarms, GuardDuty, CloudTrail and AWS Budgets.

## 14. Troubleshooting

| Symptom | Fix |
| --- | --- |
| terraform plan: access denied | Your SSO role lacks a permission; add it or use a broader short-lived role for the first apply |
| kubectl times out from your laptop | Your public IP changed; update api\_allowed\_cidrs and apply again |
| SSM instance not Online | Wait 5 minutes; check the NAT gateway exists and the instance has the SSM role |
| Agent offline | Wrong Jenkins URL, or label is not build-agent. Check journalctl -u jenkins-agent |
| Gitleaks fails on the first run | Old secrets in Git history; use the new repo, or create a baseline |
| Quality gate hangs | SonarQube webhook missing (phase 9 step 4) |
| ECR: tag invalid, immutable | Same tag pushed twice; start a new build |
| Pods in CreateContainerConfigError | Secret easycrud-db missing; check the deploy stage log |
| ALB has no healthy targets | Load Balancer Controller not running, or NetworkPolicy CIDR does not match your VPC CIDR |

## Appendix A. Launching the three EC2s by hand (console)

Only do this if you do not want Terraform to create them. You still need the VPC, subnets and IAM roles first, so run Terraform with the ci.tf resources removed, or create the matching roles manually. In EC2, Launch instance:

| Setting | Controller | Agent | SonarQube |
| --- | --- | --- | --- |
| Name | easycrud-prod-jenkins-controller | easycrud-prod-jenkins-agent | easycrud-prod-sonarqube |
| AMI | Ubuntu Server 22.04 LTS | same | same |
| Instance type | t3.medium | t3.large | t3.medium |
| Key pair | Proceed without a key pair | same | same |
| Subnet | a private subnet | same | same |
| Auto-assign public IP | Disable | Disable | Disable |
| Security group | inbound 8080 from the agent SG and the SonarQube SG only | no inbound rules | inbound 9000 from the agent SG and the controller SG only |
| Storage | 30 GiB gp3, encrypted | 50 GiB gp3, encrypted | 30 GiB gp3, encrypted |
| IAM instance profile | role with AmazonSSMManagedInstanceCore | that role plus the scoped agent policy (ECR push on the 2 repos, eks:DescribeCluster, rds:DescribeDBInstances, secretsmanager:GetSecretValue on the DB secret) | role with AmazonSSMManagedInstanceCore |
| Advanced: metadata | IMDSv2 required, hop limit 1 | same | same |
| Advanced: user data | paste scripts/install-jenkins-controller.sh | paste scripts/install-jenkins-agent.sh | paste scripts/install-sonarqube.sh |

After launch, continue from phase 5. For the Jenkins agent to deploy, you must also create the EKS access entry for its role (Terraform does this in eks.tf), scoped to the easycrud namespace with the AmazonEKSEditPolicy.

## Appendix B. Using an Ubuntu Server EC2 as your admin machine

Use this if you have no Ubuntu server to work from. It is a temporary machine that runs Terraform, kubectl and helm. It holds powerful AWS permissions, so lock it down and delete it when the setup is finished. In EC2, Launch instance:

| Setting | Value |
| --- | --- |
| Name | easycrud-admin |
| AMI | Ubuntu Server 24.04 LTS (or 22.04) |
| Instance type | t3.small |
| Key pair | Proceed without a key pair (connect with Session Manager) |
| Network | Default VPC, public subnet, auto-assign public IP enabled (it needs outbound internet) |
| Security group | No inbound rules |
| Storage | 20 GiB gp3, encrypted |
| IAM instance profile | Role with AmazonSSMManagedInstanceCore plus the permissions Terraform needs (README section 9). Avoid long-lived AdministratorAccess |
| Advanced: metadata | IMDSv2 required |

Then:

```bash
aws ssm start-session --target <admin-instance-id>
sudo -iu ubuntu
aws sts get-caller-identity      # the instance role supplies credentials
```

Follow phase 1 from the base packages onward, and skip the aws configure sso and aws sso login lines. Set api\_allowed\_cidrs in phase 2 to this machine's public IP.

This machine has no SSH, so open the Jenkins and SonarQube pages by running the two port-forward commands from your own laptop (with the AWS CLI and Session Manager plugin installed there) instead of the ssh -L tunnels. When setup is done, stop the machine; the Terraform state is in S3, so you can start it or launch a new one whenever you need to change the infrastructure.
