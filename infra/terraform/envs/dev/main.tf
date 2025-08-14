# ---------- Locals ----------
locals {
  name = "${var.project}-${var.env}"
}

# ---------- ECR (for API images) ----------
resource "aws_ecr_repository" "api" {
  name = "${local.name}-api"
  image_scanning_configuration { scan_on_push = true }
  force_delete = true
  tags         = { Name = "${local.name}-api-ecr" }
}

# ---------- Networking (VPC, Subnets, Routing) ----------
resource "aws_vpc" "mwe" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Two PUBLIC subnets (auto-assign public IPs) in two AZs
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.mwe.id
  cidr_block              = cidrsubnet(aws_vpc.mwe.cidr_block, 4, count.index) # 10.20.0.0/20, 10.20.16.0/20
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name}-public-${count.index}" }
}

# Two PRIVATE subnets in two AZs
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.mwe.id
  cidr_block        = cidrsubnet(aws_vpc.mwe.cidr_block, 4, count.index + 8) # 10.20.128.0/20, 10.20.144.0/20
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${local.name}-private-${count.index}" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.mwe.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${local.name}-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

# Public route table → Internet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.mwe.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route table → NAT
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.mwe.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${local.name}-private-rt" }
}

resource "aws_route_table_association" "private_assoc" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------- ECS (cluster only for now) ----------
resource "aws_ecs_cluster" "this" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${local.name}-cluster" }
}

# ---------- IAM for ECS tasks ----------
# Trust policy document for ECS tasks
data "aws_iam_policy_document" "ecs_task_exec_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

# Execution role: pull from ECR, push logs
resource "aws_iam_role" "ecs_task_execution" {
  name               = "${local.name}-ecs-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_exec_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec_attach" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role: app's own permissions (none yet)
resource "aws_iam_role" "ecs_task_role" {
  name               = "${local.name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_exec_assume.json
}

# ---------- CloudWatch Logs ----------
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.name}-api"
  retention_in_days = 14
}

# ---------- Data bucket (versioned) ----------
resource "random_id" "sfx" {
  byte_length = 3
}

resource "aws_s3_bucket" "data" {
  bucket = "${local.name}-data-${random_id.sfx.hex}"
  tags   = { Name = "${local.name}-data" }
}

resource "aws_s3_bucket_versioning" "data_v" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration { status = "Enabled" }
}

# ---------- GitHub OIDC for CI/CD ----------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "gha_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  name               = "${local.name}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.gha_assume.json
  tags               = { Name = "${local.name}-github-deploy" }
}

resource "aws_iam_role_policy_attachment" "gha_poweruser" {
  role       = aws_iam_role.gha_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# ALB security group: allow inbound HTTP from anywhere, allow all egress
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = aws_vpc.mwe.id

  ingress {
    description      = "Allow HTTP from the internet"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "${local.name}-alb-sg" }
}


# ECS service SG: only allow app port (8080) from ALB SG, allow all egress
resource "aws_security_group" "ecs_service" {
  name        = "${local.name}-ecs-svc-sg"
  description = "Security group for ECS Fargate service"
  vpc_id      = aws_vpc.mwe.id

  ingress {
    description     = "Allow app traffic from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "${local.name}-ecs-svc-sg" }
}


# Public Application Load Balancer in the two PUBLIC subnets
resource "aws_lb" "api_alb" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false

  security_groups = [aws_security_group.alb.id]
  subnets         = [for s in aws_subnet.public : s.id]

  tags = { Name = "${local.name}-alb" }
}


# Target group for Fargate tasks (targets are ENI IPs of tasks)
resource "aws_lb_target_group" "api_tg" {
  name        = "${local.name}-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.mwe.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${local.name}-tg" }
}


# Listener on :80 forwarding to the target group
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api_tg.arn
  }
}


# ---------- ECS Task Definition (Fargate) ----------
resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"  # 0.5 vCPU
  memory                   = "1024" # 1 GB
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = "${aws_ecr_repository.api.repository_url}:api-latest"
      essential = true
      portMappings = [{
        containerPort = 8080
        hostPort      = 8080
        protocol      = "tcp"
      }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "api"
        }
      }
      environment = [
        { name = "ENV", value = var.env },
        { name = "PROJECT", value = var.project }
      ]
    }
  ])
}


# ---------- ECS Service (Fargate behind ALB) ----------
resource "aws_ecs_service" "api" {
  name            = "${local.name}-api-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [for s in aws_subnet.private : s.id]
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api_tg.arn
    container_name   = "api"
    container_port   = 8080
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  depends_on = [
    aws_lb_listener.http
  ]
}

