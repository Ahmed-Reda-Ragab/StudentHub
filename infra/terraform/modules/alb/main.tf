# ALB module — one public ALB, two target groups (blue / green) and a WEIGHTED forward
# action, so every traffic-shifting strategy is just a weight change (CONVENTIONS §6):
#
#   all-at-once / blue-green : blue_weight=100,green_weight=0  ->  0/100     (scenarios 44, 45)
#   canary                   : 90/10 -> 50/50 -> 0/100                       (scenario 46)
#   rollback                 : flip the weights back (seconds, no redeploy)
#
# NOTE: if CI flips the weights with `aws elbv2 modify-listener` (deploy role), update
# blue_weight/green_weight in tfvars afterwards, or the next apply reverts the switch (drift).

data "aws_vpc" "this" {
  id = var.vpc_id
}

locals {
  https  = var.https_enabled != null ? var.https_enabled : var.certificate_arn != null
  colors = toset(["blue", "green"])
}

# ---------------------------------------------------------------- security group

resource "aws_security_group" "this" {
  name        = "${var.name}-alb"
  description = "Public ALB for ${var.name}"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each = toset(var.ingress_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "HTTP from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = toset(var.ingress_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "HTTPS from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

# Egress only to targets inside the VPC on the target port (least privilege).
resource "aws_vpc_security_group_egress_rule" "targets" {
  security_group_id = aws_security_group.this.id
  description       = "To targets on the traffic/health-check port"
  ip_protocol       = "tcp"
  from_port         = var.target_port
  to_port           = var.target_port
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

# ---------------------------------------------------------------- load balancer

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.this.id]
  subnets            = var.subnet_ids

  idle_timeout               = var.idle_timeout
  drop_invalid_header_fields = true # reject request smuggling-style malformed headers
  enable_deletion_protection = var.enable_deletion_protection

  dynamic "access_logs" {
    for_each = var.access_logs_bucket == null ? [] : [var.access_logs_bucket]
    content {
      bucket  = access_logs.value
      prefix  = var.name
      enabled = true
    }
  }

  tags = { Name = "${var.name}-alb" }
}

resource "aws_lb_target_group" "this" {
  for_each = local.colors

  name                 = "${var.name}-${each.key}"
  vpc_id               = var.vpc_id
  target_type          = var.target_type
  protocol             = "HTTP"
  port                 = var.target_port
  deregistration_delay = var.deregistration_delay

  # /ready = readiness (DB ping). Two consecutive results at 10s flip the state:
  # a bad release is pulled out in ~20s, a good one gets traffic ~20s after boot.
  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${var.name}-${each.key}", Color = each.key }
}

# ---------------------------------------------------------------- listeners
#
# Who owns the traffic split?
#   weights_managed_externally = false (default) → Terraform: blue_weight / green_weight
#   weights_managed_externally = true            → CodeDeploy, ECS deployments or CI
#     (`aws elbv2 modify-listener`) own it; Terraform creates the listener once and then
#     ignores default_action, so a later `apply` never flips production traffic back.
# Terraform cannot make `ignore_changes` conditional, hence two variants selected by count.

locals {
  forward_groups = [
    { arn = aws_lb_target_group.this["blue"].arn, weight = var.blue_weight },
    { arn = aws_lb_target_group.this["green"].arn, weight = var.green_weight },
  ]
  http_forwards  = local.https ? [] : [1] # without a certificate HTTP carries traffic
  http_redirects = local.https ? [1] : [] # with one, HTTP only redirects to HTTPS
}

resource "aws_lb_listener" "http" {
  count = var.weights_managed_externally ? 0 : 1

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.http_redirects
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.http_forwards
    content {
      type = "forward"
      forward {
        dynamic "target_group" {
          for_each = local.forward_groups
          content {
            arn    = target_group.value.arn
            weight = target_group.value.weight
          }
        }
        dynamic "stickiness" {
          for_each = var.stickiness_duration > 0 ? [var.stickiness_duration] : []
          content {
            enabled  = true
            duration = stickiness.value
          }
        }
      }
    }
  }
}

resource "aws_lb_listener" "http_external" {
  count = var.weights_managed_externally ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.http_redirects
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.http_forwards
    content {
      type = "forward"
      forward {
        dynamic "target_group" {
          for_each = local.forward_groups
          content {
            arn    = target_group.value.arn
            weight = target_group.value.weight
          }
        }
        dynamic "stickiness" {
          for_each = var.stickiness_duration > 0 ? [var.stickiness_duration] : []
          content {
            enabled  = true
            duration = stickiness.value
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

resource "aws_lb_listener" "https" {
  count = local.https && !var.weights_managed_externally ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type = "forward"
    forward {
      dynamic "target_group" {
        for_each = local.forward_groups
        content {
          arn    = target_group.value.arn
          weight = target_group.value.weight
        }
      }
      dynamic "stickiness" {
        for_each = var.stickiness_duration > 0 ? [var.stickiness_duration] : []
        content {
          enabled  = true
          duration = stickiness.value
        }
      }
    }
  }
}

resource "aws_lb_listener" "https_external" {
  count = local.https && var.weights_managed_externally ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type = "forward"
    forward {
      dynamic "target_group" {
        for_each = local.forward_groups
        content {
          arn    = target_group.value.arn
          weight = target_group.value.weight
        }
      }
      dynamic "stickiness" {
        for_each = var.stickiness_duration > 0 ? [var.stickiness_duration] : []
        content {
          enabled  = true
          duration = stickiness.value
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

locals {
  http_listener_arn    = one(concat(aws_lb_listener.http[*].arn, aws_lb_listener.http_external[*].arn))
  https_listener_arn   = one(concat(aws_lb_listener.https[*].arn, aws_lb_listener.https_external[*].arn))
  traffic_listener_arn = local.https ? local.https_listener_arn : local.http_listener_arn
}

# /metrics is for Prometheus inside the network only. The app can protect it with
# METRICS_TOKEN, but the edge must never expose it (defence in depth, CONVENTIONS §3).
resource "aws_lb_listener_rule" "block_metrics" {
  listener_arn = local.traffic_listener_arn
  priority     = 1

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }

  condition {
    path_pattern {
      values = ["/metrics", "/metrics/*"]
    }
  }
}
