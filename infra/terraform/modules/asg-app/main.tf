# ASG app module — immutable EC2 fleet behind an ALB target group (scenarios 40–48).
#
#   launch template (AL2023 or Packer AMI, IMDSv2, user data below)
#     └─ ASG (ELB health checks, instance refresh with auto rollback, optional Spot)
#          └─ target tracking: CPU 50% + ALBRequestCountPerTarget
#
# Deploy contract (CONVENTIONS §4): the image to run lives in SSM
#   /<project>/<env>/deploy/<color>/IMAGE_URI
# Terraform only seeds it; CI does put-parameter + start-instance-refresh.

# Provider default_tags do NOT reach instances launched by an ASG; copy them into
# tag_specifications so instances carry Project/Env (SSM Run Command scoping, Ansible inventory, cost).
data "aws_default_tags" "this" {}

data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == null ? 1 : 0

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.arch}"
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

locals {
  # A new AL2023 release changes image_id -> new launch template version -> instance refresh
  # on the next apply. That IS the patching story for immutable infrastructure.
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ssm_parameter.al2023[0].insecure_value

  # /student-app/lab/app -> /student-app/lab/deploy/blue/IMAGE_URI
  env_prefix           = trimsuffix(trimsuffix(var.ssm_prefix, "/"), "/app")
  image_parameter_name = coalesce(var.image_parameter_name, "${local.env_prefix}/deploy/${var.color}/IMAGE_URI")

  burstable = can(regex("^t[0-9]", var.instance_type))

  security_group_ids = concat(aws_security_group.this[*].id, var.security_group_ids)

  instance_tags = merge(data.aws_default_tags.this.tags, {
    Name  = var.name
    Role  = "app" # Ansible aws_ec2 inventory group role_app (CONVENTIONS §7)
    Color = var.color
  })

  spot_types = length(var.spot_instance_types) > 0 ? var.spot_instance_types : [var.instance_type]

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    ssm_prefix               = trimsuffix(var.ssm_prefix, "/")
    image_parameter_name     = local.image_parameter_name
    color                    = var.color
    host_port                = var.host_port
    container_port           = var.container_port
    install_docker           = !var.golden_ami
    install_codedeploy_agent = var.install_codedeploy_agent
    compose_version          = var.compose_version
    log_group_name           = var.log_group_name == null ? "" : var.log_group_name
  })
}

# ---------------------------------------------------------------- deploy parameter

resource "aws_ssm_parameter" "image_uri" {
  name        = local.image_parameter_name
  type        = "String"
  value       = var.image_uri
  description = "Image the ${var.color} ASG boots. Seeded by Terraform, owned by CI (put-parameter + instance refresh)."

  lifecycle {
    ignore_changes = [value]
  }
}

# ---------------------------------------------------------------- security group

resource "aws_security_group" "this" {
  count = var.create_security_group ? 1 : 0

  name        = "${var.name}-app"
  description = "App instances of ${var.name}"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-app" }
}

resource "aws_vpc_security_group_ingress_rule" "from_alb" {
  count = var.create_security_group && var.alb_security_group_id != null ? 1 : 0

  security_group_id            = aws_security_group.this[0].id
  description                  = "App traffic + health checks from the ALB only"
  ip_protocol                  = "tcp"
  from_port                    = var.host_port
  to_port                      = var.host_port
  referenced_security_group_id = var.alb_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "web" {
  for_each = var.create_security_group ? toset(["80", "443"]) : toset([])

  security_group_id = aws_security_group.this[0].id
  description       = "Outbound tcp/${each.value} (dnf, ECR, SSM, CloudWatch)"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "data" {
  for_each = var.create_security_group ? toset(["3306", "6379"]) : toset([])

  security_group_id = aws_security_group.this[0].id
  description       = "MySQL / Redis inside the VPC"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

# ---------------------------------------------------------------- launch template

resource "aws_launch_template" "this" {
  name_prefix            = "${var.name}-"
  description            = "student-app ${var.color} (${var.golden_ami ? "golden AMI" : "AL2023 + docker at boot"})"
  image_id               = local.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = local.security_group_ids
  user_data              = base64encode(local.user_data)
  update_default_version = true

  iam_instance_profile {
    name = var.instance_profile
  }

  # IMDSv2 only; hop limit 1 keeps the container away from the instance credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda" # AL2023 root device
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size
      encrypted             = true
      delete_on_termination = true
    }
  }

  # 1-minute EC2 metrics make CPU target tracking react ~5x faster (scenario 48) but cost extra
  # per instance; the ASG group metrics below are free either way.
  monitoring {
    enabled = var.detailed_monitoring
  }

  dynamic "credit_specification" {
    for_each = local.burstable ? [1] : []
    content {
      cpu_credits = var.cpu_credits
    }
  }

  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])
    content {
      resource_type = tag_specifications.value
      tags          = local.instance_tags
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------- auto scaling group

# Ordering edge only (see var.wait_for).
resource "terraform_data" "wait_for" {
  input = var.wait_for
}

resource "aws_autoscaling_group" "this" {
  name                = var.name
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min
  max_size            = var.max
  desired_capacity    = var.desired

  # ELB health = the /ready check: an instance whose app cannot reach the DB is replaced.
  health_check_type         = "ELB"
  health_check_grace_period = var.health_check_grace_period
  default_instance_warmup   = var.instance_warmup
  target_group_arns         = var.target_group_arns
  wait_for_capacity_timeout = "10m"
  # Spot: launch a replacement as soon as AWS signals elevated interruption risk (rebalance
  # recommendation), before the 2-minute notice (scenario 48).
  capacity_rebalance = var.spot_enabled

  # Free at 1-minute granularity; feeds the dashboard.
  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  dynamic "launch_template" {
    for_each = var.spot_enabled ? [] : [1]
    content {
      id      = aws_launch_template.this.id
      version = aws_launch_template.this.latest_version
    }
  }

  dynamic "mixed_instances_policy" {
    for_each = var.spot_enabled ? [1] : []
    content {
      instances_distribution {
        on_demand_base_capacity                  = var.on_demand_base_capacity
        on_demand_percentage_above_base_capacity = var.on_demand_percentage_above_base
        # Picks the pools least likely to be interrupted at a low price (AWS recommendation).
        spot_allocation_strategy = "price-capacity-optimized"
      }

      launch_template {
        launch_template_specification {
          launch_template_id = aws_launch_template.this.id
          version            = aws_launch_template.this.latest_version
        }

        dynamic "override" {
          for_each = local.spot_types
          content {
            instance_type = override.value
          }
        }
      }
    }
  }

  # Any launch template change (AMI, user data, type) rolls the fleet automatically.
  # Image changes come from CI instead: put-parameter + start-instance-refresh (same settings).
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = var.refresh_min_healthy_percentage
      max_healthy_percentage = var.refresh_max_healthy_percentage
      instance_warmup        = var.instance_warmup
      skip_matching          = false
      auto_rollback          = var.refresh_auto_rollback

      # Scenario 42: a release that trips the 5xx / unhealthy-host alarms mid-refresh is rolled back.
      dynamic "alarm_specification" {
        for_each = length(var.refresh_alarm_names) > 0 ? [1] : []
        content {
          alarms = var.refresh_alarm_names
        }
      }
    }
  }

  dynamic "tag" {
    for_each = { Name = var.name, Color = var.color }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false # instances get their tags from the launch template
    }
  }

  lifecycle {
    # Scaling policies (and CI scaling the idle color) own desired capacity after creation.
    ignore_changes = [desired_capacity]
  }

  depends_on = [terraform_data.wait_for]
}

# ---------------------------------------------------------------- scaling policies

resource "aws_autoscaling_policy" "cpu" {
  count = var.enable_cpu_scaling ? 1 : 0

  name                   = "${var.name}-cpu-${var.cpu_target}"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target
  }
}

# Requests per target is the better signal for a web tier: it scales before CPU saturates.
resource "aws_autoscaling_policy" "requests" {
  count = var.enable_request_scaling ? 1 : 0

  name                   = "${var.name}-req-${var.requests_per_target}"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.alb_arn_suffix}/${var.target_group_arn_suffix}"
    }
    target_value = var.requests_per_target
  }

  lifecycle {
    precondition {
      condition     = var.alb_arn_suffix != null && var.target_group_arn_suffix != null
      error_message = "enable_request_scaling needs alb_arn_suffix and target_group_arn_suffix."
    }
  }
}
