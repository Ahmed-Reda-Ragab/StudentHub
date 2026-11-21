# Network module — VPC with public + private subnets per AZ (CONVENTIONS §6).
#
#   public  subnets: ALB, NAT, and (cheap mode) app instances with public IPs
#   private subnets: RDS, ElastiCache, ECS/EKS tasks when a NAT exists
#
# NAT is OFF by default: it is the single most expensive "idle" item in a lab VPC.

data "aws_availability_zones" "available" {
  state = "available"

  # Skip Local Zones / Wavelength zones that need an explicit opt-in.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Public subnets take the first blocks, private subnets start halfway through the VPC,
  # so adding AZs later never renumbers an existing subnet.
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.cidr, var.subnet_newbits, i)]
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.cidr, var.subnet_newbits, i + pow(2, var.subnet_newbits - 1))]

  nat_count = var.enable_nat ? (var.single_nat ? 1 : var.az_count) : 0
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for RDS/ElastiCache endpoints and interface endpoints

  tags = { Name = var.name }
}

# Lock down the default SG: nothing should ever use it (CIS 5.4).
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-deny" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  # kubernetes.io/role/elb lets the AWS Load Balancer Controller (stack 60) discover
  # public subnets for internet-facing ALBs. Harmless everywhere else.
  tags = merge(
    {
      Name                     = "${var.name}-public-${local.azs[count.index]}"
      Tier                     = "public"
      "kubernetes.io/role/elb" = "1"
    },
    var.public_subnet_tags,
  )
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(
    {
      Name                              = "${var.name}-private-${local.azs[count.index]}"
      Tier                              = "private"
      "kubernetes.io/role/internal-elb" = "1"
    },
    var.private_subnet_tags,
  )
}

# ---------------------------------------------------------------- routing

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ so per-AZ NAT (single_nat=false) keeps traffic in its AZ.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------- NAT (optional, $$)

resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"
  tags   = { Name = "${var.name}-nat-${local.azs[count.index]}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${var.name}-${local.azs[count.index]}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_nat" {
  count = var.enable_nat ? var.az_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat ? 0 : count.index].id
}

# ---------------------------------------------------------------- endpoints

# Gateway endpoints are free (interface endpoints are ~7 USD/month each, so none here).
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], aws_route_table.private[*].id)

  tags = { Name = "${var.name}-s3" }
}

data "aws_region" "current" {}
