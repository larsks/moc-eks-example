# --- IAM role for SSM ---

resource "aws_iam_role" "bastion" {
  name = "${var.cluster_name}-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.cluster_name}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# --- Security group (outbound only) ---

resource "aws_security_group" "bastion" {
  name        = "${var.cluster_name}-bastion-sg"
  description = "SSM bastion - outbound only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.cluster_name}-bastion-sg" }
}

resource "aws_vpc_security_group_egress_rule" "bastion_all_outbound" {
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Allow bastion to reach EKS API server (port 443 on the cluster security group)
resource "aws_security_group_rule" "bastion_to_eks_api" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.bastion.id
}

# --- AMI lookup ---

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# --- Bastion instance ---

resource "aws_instance" "bastion" {
  ami                  = data.aws_ami.amazon_linux.id
  instance_type        = var.bastion_instance_type
  subnet_id            = values(aws_subnet.private)[0].id
  iam_instance_profile = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "${var.cluster_name}-bastion" }
}
