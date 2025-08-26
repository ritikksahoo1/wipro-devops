terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}

# Use default VPC + first public subnet for simplicity
data "aws_vpc" "default" { default = true }
data "aws_subnets" "public" {
  filter { name = "vpc-id" values = [data.aws_vpc.default.id] }
}

# Ubuntu 22.04 LTS AMI (Canonical)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter { name = "name" values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"] }
  filter { name = "virtualization-type" values = ["hvm"] }
}

# Import your SSH public key as an EC2 key pair
resource "aws_key_pair" "this" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)
}

# Security Group for Jenkins Master
resource "aws_security_group" "jenkins_sg" {
  name        = "jenkins-sg"
  description = "Allow SSH and Jenkins UI"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from your IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "Jenkins UI (8080) from your IP"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group for Application Node (Tomcat)
resource "aws_security_group" "app_sg" {
  name        = "app-sg"
  description = "Allow SSH and Tomcat"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from Jenkins SG"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    security_groups = [aws_security_group.jenkins_sg.id]
  }

  # For demo: open Tomcat 8080 to the world so you can view in a browser.
  # (For tighter security, replace with [var.my_ip_cidr].)
  ingress {
    description = "Tomcat 8080 open"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Jenkins Master EC2
resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.micro"
  subnet_id                   = data.aws_subnets.public.ids[0]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.this.key_name
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id]
  tags = { Name = "jenkins-master" }

  user_data = <<-EOF
    #!/bin/bash
    set -eux

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y openjdk-11-jdk git curl gnupg maven ansible

    # Jenkins repo
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | tee \
      /usr/share/keyrings/jenkins-keyring.asc > /dev/null
    echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
      https://pkg.jenkins.io/debian-stable binary/ | tee \
      /etc/apt/sources.list.d/jenkins.list > /dev/null

    apt-get update -y
    apt-get install -y jenkins
    systemctl enable --now jenkins

    # Allow Jenkins user to run ansible
    usermod -aG sudo jenkins
  EOF
}

# Application Node EC2
resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.micro"
  subnet_id                   = data.aws_subnets.public.ids[0]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.this.key_name
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  tags = { Name = "app-node" }

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y openjdk-11-jre python3 python3-apt
  EOF
}
