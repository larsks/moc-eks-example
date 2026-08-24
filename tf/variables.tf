variable "cluster_name" {
  type    = string
  default = "moc-eks"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.251.0.0/16"
}

variable "public_subnet_cidrs" {
  type = map(string)
  default = {
    "us-east-1a" = "10.251.1.0/24"
    "us-east-1b" = "10.251.2.0/24"
  }
}

variable "private_subnet_cidrs" {
  type = map(string)
  default = {
    "us-east-1a" = "10.251.10.0/24"
    "us-east-1b" = "10.251.20.0/24"
  }
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "eks_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_desired_count" {
  type    = number
  default = 2
}

variable "node_min_count" {
  type    = number
  default = 1
}

variable "node_max_count" {
  type    = number
  default = 4
}

variable "bastion_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS public API endpoint. Restrict to your IP for security."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
