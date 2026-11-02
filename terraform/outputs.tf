output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "lb_controller_role_arn" {
  value = module.lb_controller_irsa.iam_role_arn
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "db_instance_id" {
  value = aws_db_instance.this.identifier
}

output "db_endpoint" {
  value = aws_db_instance.this.address
}

output "db_secret_arn" {
  value = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "jenkins_controller_instance_id" {
  value = aws_instance.jenkins_controller.id
}

output "jenkins_controller_private_ip" {
  value = aws_instance.jenkins_controller.private_ip
}

output "jenkins_agent_instance_id" {
  value = aws_instance.jenkins_agent.id
}

output "sonarqube_instance_id" {
  value = var.create_sonarqube ? aws_instance.sonarqube[0].id : null
}

output "sonarqube_private_ip" {
  value = var.create_sonarqube ? aws_instance.sonarqube[0].private_ip : null
}
