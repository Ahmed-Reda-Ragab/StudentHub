# ElastiCache (Valkey/Redis) — scenario 49: move sessions + cache off MySQL so the web tier
# is truly stateless and `migrate --isolated` gets a real cache lock (CONVENTIONS §2).
#
# Single node, no replica, no snapshots: it is a cache. Losing it logs users out, nothing more.

locals {
  ssm_prefix = trimsuffix(var.ssm_prefix, "/")
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-cache"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "this" {
  name        = "${var.name}-cache"
  description = "${var.engine} for ${var.name}: cache port from app security groups only"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-cache" }
}

resource "aws_vpc_security_group_ingress_rule" "from_sg" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "Cache from app SG"
  ip_protocol                  = "tcp"
  from_port                    = var.port
  to_port                      = var.port
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name}-cache"
  description          = "student-app sessions + cache (${var.name})"

  engine             = var.engine
  engine_version     = var.engine_version
  node_type          = var.node_type
  num_cache_clusters = 1 # primary only; scenario variants can add a replica + automatic failover
  port               = var.port

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.this.id]

  automatic_failover_enabled = false
  multi_az_enabled           = false
  at_rest_encryption_enabled = true
  transit_encryption_enabled = var.transit_encryption_enabled
  snapshot_retention_limit   = 0 # no backups for a cache
  apply_immediately          = true
}

locals {
  host = aws_elasticache_replication_group.this.primary_endpoint_address
}

resource "aws_ssm_parameter" "host" {
  name           = "${local.ssm_prefix}/REDIS_HOST"
  type           = "String"
  insecure_value = var.transit_encryption_enabled ? "tls://${local.host}" : local.host
  description    = "Managed by Terraform (modules/elasticache-redis)"
}

resource "aws_ssm_parameter" "port" {
  name           = "${local.ssm_prefix}/REDIS_PORT"
  type           = "String"
  insecure_value = tostring(var.port)
  description    = "Managed by Terraform (modules/elasticache-redis)"
}
