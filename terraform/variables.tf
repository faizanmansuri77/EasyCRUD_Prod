variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "easycrud"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "single_nat_gateway" {
  description = "true = one NAT gateway (cheaper). false = one per AZ (HA)."
  type        = bool
  default     = true
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the PUBLIC EKS API endpoint (your office/VPN IP, e.g. 203.0.113.10/32). 0.0.0.0/0 is rejected on purpose."
  type        = list(string)

  validation {
    condition     = length(var.api_allowed_cidrs) > 0 && !contains(var.api_allowed_cidrs, "0.0.0.0/0")
    error_message = "Provide at least one specific CIDR and do not use 0.0.0.0/0."
  }
}

variable "cluster_version" {
  description = "Check supported versions first: aws eks describe-cluster-versions"
  type        = string
  default     = "1.34"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "app_namespace" {
  type    = string
  default = "easycrud"
}

# ---- RDS ----
variable "db_name" {
  type    = string
  default = "student_db"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "db_engine_version" {
  description = "Verify: aws rds describe-db-engine-versions --engine mariadb --query 'DBEngineVersions[].EngineVersion'"
  type        = string
  default     = "11.8"
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "db_deletion_protection" {
  description = "Set to false before 'terraform destroy'."
  type        = bool
  default     = true
}

# ---- CI servers ----
variable "controller_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "agent_instance_type" {
  type    = string
  default = "t3.large"
}

variable "create_sonarqube" {
  type    = bool
  default = true
}

variable "sonarqube_instance_type" {
  type    = string
  default = "t3.medium"
}
