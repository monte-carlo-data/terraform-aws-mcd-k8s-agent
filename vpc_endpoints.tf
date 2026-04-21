# -----------------------------------------------------------------------------
# VPC Endpoints for AWS Services (conditional)
# -----------------------------------------------------------------------------
# Creates VPC endpoints for AWS services used by the agent, keeping traffic off
# the public internet. This reduces NAT gateway costs and improves security.
# Controlled by var.networking.create_vpc_endpoints (default: true).
# Set to false if your VPC already has these endpoints.
# -----------------------------------------------------------------------------

locals {
  create_vpc_endpoints = var.networking.create_vpc_endpoints

  # Route table IDs for the S3 Gateway endpoint.
  # Created VPC: use the module output directly.
  # Existing VPC: look up route tables associated with the provided subnets.
  effective_private_route_table_ids = local.create_vpc_endpoints ? (
    var.networking.create_vpc
    ? module.vpc[0].private_route_table_ids
    : distinct([for rt in data.aws_route_table.private_subnet : rt.route_table_id])
  ) : []
}

# --- Data sources (existing VPC only) ---

data "aws_route_table" "private_subnet" {
  for_each  = (!var.networking.create_vpc && local.create_vpc_endpoints) ? toset(var.networking.existing_private_subnet_ids) : toset([])
  subnet_id = each.value
}

# --- Shared security group for Interface endpoints ---

resource "aws_security_group" "vpc_endpoints" {
  count       = local.create_vpc_endpoints ? 1 : 0
  name        = "${local.effective_cluster_name}-vpc-endpoints-sg"
  description = "Controls access to VPC Interface endpoints"
  vpc_id      = local.effective_vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected[0].cidr_block]
  }

  tags = merge(local.default_tags, {
    Name = "${local.effective_cluster_name}-vpc-endpoints-sg"
  })
}

# --- S3 Gateway Endpoint ---

resource "aws_vpc_endpoint" "s3" {
  count             = local.create_vpc_endpoints ? 1 : 0
  vpc_id            = local.effective_vpc_id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.effective_private_route_table_ids

  tags = merge(local.default_tags, {
    Name = "${local.effective_cluster_name}-s3-endpoint"
  })
}

# --- Secrets Manager Interface Endpoint ---

resource "aws_vpc_endpoint" "secretsmanager" {
  count             = local.create_vpc_endpoints ? 1 : 0
  vpc_id            = local.effective_vpc_id
  service_name      = "com.amazonaws.${local.region}.secretsmanager"
  vpc_endpoint_type = "Interface"

  subnet_ids         = local.effective_private_subnet_ids
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  private_dns_enabled = true

  tags = merge(local.default_tags, {
    Name = "${local.effective_cluster_name}-secretsmanager-endpoint"
  })

  lifecycle {
    precondition {
      condition     = data.aws_vpc.selected[0].enable_dns_hostnames
      error_message = "The VPC must have DNS hostnames enabled for Interface VPC endpoints (private_dns_enabled requires it)."
    }
  }
}

# --- STS Interface Endpoint ---

resource "aws_vpc_endpoint" "sts" {
  count             = local.create_vpc_endpoints ? 1 : 0
  vpc_id            = local.effective_vpc_id
  service_name      = "com.amazonaws.${local.region}.sts"
  vpc_endpoint_type = "Interface"

  subnet_ids         = local.effective_private_subnet_ids
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  private_dns_enabled = true

  tags = merge(local.default_tags, {
    Name = "${local.effective_cluster_name}-sts-endpoint"
  })
}

# --- EC2 Interface Endpoint ---

resource "aws_vpc_endpoint" "ec2" {
  count             = local.create_vpc_endpoints ? 1 : 0
  vpc_id            = local.effective_vpc_id
  service_name      = "com.amazonaws.${local.region}.ec2"
  vpc_endpoint_type = "Interface"

  subnet_ids         = local.effective_private_subnet_ids
  security_group_ids = [aws_security_group.vpc_endpoints[0].id]

  private_dns_enabled = true

  tags = merge(local.default_tags, {
    Name = "${local.effective_cluster_name}-ec2-endpoint"
  })
}
