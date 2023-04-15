locals {
  cidr_block  = "10.0.0.0/16"
  cidr_subnet = cidrsubnets(local.cidr_block, 8)[0]
  ip          = jsondecode(data.http.ip.response_body).ip # Get ip from http data
}

data "aws_region" "current" {} # need region for vpc endpoint

data "http" "ip" { # get local IP for security groups
  url = "https://api.ipify.org?format=json"
  request_headers = {
    Accept = "application/json"
  }
}

data "aws_ami" "amzlinux" { # get amazon linux ami for current region
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"] # amazon linux 2023
    # values = ["amzn2-ami-kernel-5.10*-x86_64-gp2"] # amazon linux 2
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "local_file" "rsa" { # get local rsa public key for temporary keypair
  filename = pathexpand("~/.ssh/id_rsa.pub")
}

resource "aws_vpc" "torrentbox" {
  cidr_block = local.cidr_block
  tags = {
    Name = "torrentbox"
  }
}

resource "aws_subnet" "torrentbox" {
  vpc_id     = aws_vpc.torrentbox.id
  cidr_block = local.cidr_subnet

  tags = {
    Name = "torrentbox"
  }
}

resource "aws_internet_gateway" "torrentbox" {
  vpc_id = aws_vpc.torrentbox.id

  tags = {
    Name = "torrentbox"
  }
}

resource "aws_route_table" "torrentbox" {
  vpc_id = aws_vpc.torrentbox.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.torrentbox.id
  }

  tags = {
    Name = "torrentbox"
  }
}

resource "aws_route_table_association" "torrentbox_public" {
  subnet_id      = aws_subnet.torrentbox.id
  route_table_id = aws_route_table.torrentbox.id
}

resource "aws_security_group" "torrentbox" {
  name   = "HTTP and SSH"
  vpc_id = aws_vpc.torrentbox.id

  ingress {
    from_port   = 9091
    to_port     = 9091
    protocol    = "tcp"
    cidr_blocks = ["${local.ip}/32"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${local.ip}/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "torrentbox"
  }
}

resource "aws_vpc_endpoint" "s3_endpoint" { # s3 endpoint for copying downloads
  vpc_id       = aws_vpc.torrentbox.id
  service_name = "com.amazonaws.${data.aws_region.current.name}.s3"
}

resource "aws_vpc_endpoint_route_table_association" "s3_endpoint_tr_association" {
  route_table_id  = aws_route_table.torrentbox.id
  vpc_endpoint_id = aws_vpc_endpoint.s3_endpoint.id
}

resource "aws_key_pair" "torrentbox" {
  key_name   = "torrentbox-key"
  public_key = data.local_file.rsa.content
}

resource "aws_s3_bucket" "torrentbox" {
  bucket_prefix = "torrentbox"
  force_destroy = true
}

resource "aws_instance" "torrentbox" {
  ami           = data.aws_ami.amzlinux.id
  instance_type = "t3.small"
  key_name      = aws_key_pair.torrentbox.id

  subnet_id                   = aws_subnet.torrentbox.id
  vpc_security_group_ids      = [aws_security_group.torrentbox.id]
  associate_public_ip_address = true
  depends_on = [
    aws_internet_gateway.torrentbox
  ]
  iam_instance_profile = aws_iam_instance_profile.torrentbox_profile.id
  root_block_device {
    volume_size           = "60"
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }
  user_data = <<EOF
#!/bin/bash
yum update -y
yum install docker -y
usermod -a -G docker ec2-user
systemctl enable docker
systemctl start docker
docker run -d --name=transmission -e PUID=1000 -e PGID=1000 -e TZ=Pacific/Auckland -p 9091:9091 -p 51413:51413 -p 51413:51413/udp -v /downloads:/downloads --restart unless-stopped lscr.io/linuxserver/transmission:latest
nohup bash -c 'while true; do aws s3 sync /downloads/complete/ s3://${aws_s3_bucket.torrentbox.id}; sleep 5; done' &
EOF
  tags = {
    "Name" : "torrentbox"
  }
}

resource "aws_iam_role" "torrentbox_role" { # iam role for copying to s3
  force_detach_policies = true
  name                  = "torrentbox_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
  inline_policy {
    name = "torrentbox_policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = ""
          Effect   = "Allow"
          Action   = [
            "s3:PutObject",
            "s3:GetObject",
            "s3:ListBucket"
          ]
          Resource = [
            "arn:aws:s3:::${aws_s3_bucket.torrentbox.id}/*",
            "arn:aws:s3:::${aws_s3_bucket.torrentbox.id}"
          ]
        },
      ]
    })
  }
}

resource "aws_iam_instance_profile" "torrentbox_profile" {
  name = "torrentbox_profile"
  role = aws_iam_role.torrentbox_role.name
}

output "torrentbox_ip" {
  value = aws_instance.torrentbox.public_ip
}

output "Warning" {
  value = "User data will take approx 15 seconds to run, give it some time before opening the URL..."
}

output "torrentbox_url" {
  value = "http://${aws_instance.torrentbox.public_ip}:9091"
}

output "bucket_url" {
  value = "https://s3.console.aws.amazon.com/s3/buckets/${aws_s3_bucket.torrentbox.id}"
}