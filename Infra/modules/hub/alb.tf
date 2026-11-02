data "aws_elb_service_account" "this" {}

data "aws_caller_identity" "current" {}

# Access logs. ELB log delivery supports SSE-S3 only, not SSE-KMS.
resource "aws_s3_bucket" "alb_logs" {
  bucket = "${local.name}-alb-logs"
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ElbLogDelivery"
      Effect    = "Allow"
      Principal = { AWS = data.aws_elb_service_account.this.arn }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

resource "aws_lb" "this" {
  name                       = local.name
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  idle_timeout               = 120
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]
}

resource "aws_lb_target_group" "hub" {
  name        = "${local.name}-hub"
  target_type = "ip"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  # With one task the ALB's 60 s drain covers a recreate deploy. With more, the hub drains itself on
  # SIGTERM (holds answered, links closed 1001, claims released; D-085), and a long delay would keep
  # a deregistered task holding its users' claims while the ALB sends their reconnects elsewhere,
  # where they are refused `409 relocated`. So ECS's SIGTERM follows deregistration after 5 s.
  deregistration_delay = var.task_count > 1 ? 5 : 60

  health_check {
    path                = "/readyz"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  # The relay serves each user's links on one hub instance (D-085). With more than one task, the
  # hub sets the `b4hub-instance` cookie on /readyz and on accepted link upgrades, and the ALB adds
  # its AWSALBAPP-* cookie naming that target, so a device's reconnect lands where its user is
  # served. One task needs no stickiness.
  stickiness {
    type            = "app_cookie"
    cookie_name     = "b4hub-instance"
    cookie_duration = 3600
    enabled         = var.task_count > 1
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.alb_ssl_policy
  certificate_arn   = aws_acm_certificate_validation.hub.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hub.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
