data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

locals {
  eks_cluster_arn = "arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${local.name}"
}

# ---------------------------------------------------------------- IAM
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Controller: SSM access only. It holds no AWS permissions for deploying anything.
resource "aws_iam_role" "jenkins_controller" {
  name               = "${local.name}-jenkins-controller"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "controller_ssm" {
  role       = aws_iam_role.jenkins_controller.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jenkins_controller" {
  name = "${local.name}-jenkins-controller"
  role = aws_iam_role.jenkins_controller.name
}

# Agent: the only identity that pushes images and deploys.
resource "aws_iam_role" "jenkins_agent" {
  name               = "${local.name}-jenkins-agent"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "agent_ssm" {
  role       = aws_iam_role.jenkins_agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "jenkins_agent" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level scoping
  }

  statement {
    sid = "EcrPushPullOurRepositoriesOnly"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }

  statement {
    sid       = "EksDescribeThisCluster"
    actions   = ["eks:DescribeCluster"]
    resources = [local.eks_cluster_arn]
  }

  statement {
    sid       = "DiscoverDatabase"
    actions   = ["rds:DescribeDBInstances"]
    resources = [aws_db_instance.this.arn]
  }

  statement {
    sid       = "ReadDatabaseCredentialSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.this.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_policy" "jenkins_agent" {
  name   = "${local.name}-jenkins-agent"
  policy = data.aws_iam_policy_document.jenkins_agent.json
}

resource "aws_iam_role_policy_attachment" "agent_custom" {
  role       = aws_iam_role.jenkins_agent.name
  policy_arn = aws_iam_policy.jenkins_agent.arn
}

resource "aws_iam_instance_profile" "jenkins_agent" {
  name = "${local.name}-jenkins-agent"
  role = aws_iam_role.jenkins_agent.name
}

# SonarQube: SSM access only
resource "aws_iam_role" "sonarqube" {
  count              = var.create_sonarqube ? 1 : 0
  name               = "${local.name}-sonarqube"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "sonarqube_ssm" {
  count      = var.create_sonarqube ? 1 : 0
  role       = aws_iam_role.sonarqube[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "sonarqube" {
  count = var.create_sonarqube ? 1 : 0
  name  = "${local.name}-sonarqube"
  role  = aws_iam_role.sonarqube[0].name
}

# ---------------------------------------------------------------- Security groups
# No SSH anywhere (use SSM Session Manager). No inbound from the internet.
resource "aws_security_group" "jenkins_controller" {
  name_prefix = "${local.name}-jenkins-controller-"
  description = "Jenkins controller (private)"
  vpc_id      = module.vpc.vpc_id
  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "jenkins_agent" {
  name_prefix = "${local.name}-jenkins-agent-"
  description = "Jenkins build agent (private, no inbound)"
  vpc_id      = module.vpc.vpc_id
  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "sonarqube" {
  count       = var.create_sonarqube ? 1 : 0
  name_prefix = "${local.name}-sonarqube-"
  description = "SonarQube (private)"
  vpc_id      = module.vpc.vpc_id
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "controller_from_agent" {
  security_group_id            = aws_security_group.jenkins_controller.id
  referenced_security_group_id = aws_security_group.jenkins_agent.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "Agent connects to controller (WebSocket)"
}

resource "aws_vpc_security_group_ingress_rule" "controller_from_sonarqube" {
  count                        = var.create_sonarqube ? 1 : 0
  security_group_id            = aws_security_group.jenkins_controller.id
  referenced_security_group_id = aws_security_group.sonarqube[0].id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "SonarQube quality-gate webhook"
}

resource "aws_vpc_security_group_ingress_rule" "sonarqube_from_agent" {
  count                        = var.create_sonarqube ? 1 : 0
  security_group_id            = aws_security_group.sonarqube[0].id
  referenced_security_group_id = aws_security_group.jenkins_agent.id
  from_port                    = 9000
  to_port                      = 9000
  ip_protocol                  = "tcp"
  description                  = "Scanner on the agent"
}

resource "aws_vpc_security_group_ingress_rule" "sonarqube_from_controller" {
  count                        = var.create_sonarqube ? 1 : 0
  security_group_id            = aws_security_group.sonarqube[0].id
  referenced_security_group_id = aws_security_group.jenkins_controller.id
  from_port                    = 9000
  to_port                      = 9000
  ip_protocol                  = "tcp"
  description                  = "Quality-gate lookup from controller"
}

# Outbound is open so the hosts can reach package repos, GitHub, ECR and the SSM service via NAT.
# Tighten with VPC endpoints + egress allow-lists if your policy requires it.
resource "aws_vpc_security_group_egress_rule" "controller_all" {
  security_group_id = aws_security_group.jenkins_controller.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "agent_all" {
  security_group_id = aws_security_group.jenkins_agent.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "sonarqube_all" {
  count             = var.create_sonarqube ? 1 : 0
  security_group_id = aws_security_group.sonarqube[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------- EC2
resource "aws_instance" "jenkins_controller" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.controller_instance_type
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.jenkins_controller.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins_controller.name
  user_data              = file("${path.module}/../scripts/install-jenkins-controller.sh")
  monitoring             = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  tags = { Name = "${local.name}-jenkins-controller" }

  lifecycle {
    ignore_changes = [ami, user_data] # never replace the Jenkins host because of an AMI release
  }
}

resource "aws_instance" "jenkins_agent" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.agent_instance_type
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.jenkins_agent.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins_agent.name
  user_data              = file("${path.module}/../scripts/install-jenkins-agent.sh")
  monitoring             = true

  # Hop limit 1: containers started by `docker build` cannot read the agent's IAM credentials
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
    encrypted   = true
  }

  tags = { Name = "${local.name}-jenkins-agent" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_instance" "sonarqube" {
  count                  = var.create_sonarqube ? 1 : 0
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.sonarqube_instance_type
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.sonarqube[0].id]
  iam_instance_profile   = aws_iam_instance_profile.sonarqube[0].name
  user_data              = file("${path.module}/../scripts/install-sonarqube.sh")
  monitoring             = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  tags = { Name = "${local.name}-sonarqube" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# The agent talks to the EKS API through the private endpoint, so the cluster security group must allow it
resource "aws_vpc_security_group_ingress_rule" "eks_api_from_agent" {
  security_group_id            = module.eks.cluster_security_group_id
  referenced_security_group_id = aws_security_group.jenkins_agent.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "Jenkins agent to EKS API (private endpoint)"
}
