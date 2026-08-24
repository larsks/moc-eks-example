output "vpc_id" {
  value = aws_vpc.main.id
}

output "cluster_name" {
  value = aws_eks_cluster.cluster.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.cluster.endpoint
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
}

output "bastion_instance_id" {
  description = "Use with: aws ssm start-session --target <id>"
  value       = aws_instance.bastion.id
}

output "bastion_security_group_id" {
  value = aws_security_group.bastion.id
}

output "kubeconfig_command" {
  description = "Run this to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.cluster.name} --region ${var.region}"
}

output "ssm_tunnel_command" {
  description = "Run this in a separate terminal to start the SSM tunnel"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters '{\"host\":[\"${replace(aws_eks_cluster.cluster.endpoint, "https://", "")}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"6443\"]}'"
}
