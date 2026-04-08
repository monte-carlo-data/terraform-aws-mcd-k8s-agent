# -----------------------------------------------------------------------------
# AWS PrivateLink (conditional)
# -----------------------------------------------------------------------------

locals {
  # Extract hostname from backend_service_url (e.g. "https://host.example.com/graphql" -> "host.example.com")
  private_link_hostname = var.private_link != null ? regex("https?://([^/:]+)", var.backend_service_url)[0] : null
}

data "aws_vpc" "selected" {
  count = (var.private_link != null || var.networking.create_vpc_endpoints) ? 1 : 0
  id    = local.effective_vpc_id
}

resource "aws_security_group" "monte_carlo_vpce" {
  count       = var.private_link != null ? 1 : 0
  name        = "${local.effective_cluster_name}-monte-carlo-vpce-sg"
  description = "Controls access to the Monte Carlo PrivateLink VPC endpoint"
  vpc_id      = local.effective_vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected[0].cidr_block]
  }

}

resource "aws_vpc_endpoint" "monte_carlo" {
  count             = var.private_link != null ? 1 : 0
  vpc_id            = local.effective_vpc_id
  service_name      = var.private_link.vpce_service_name
  service_region    = var.private_link.region
  vpc_endpoint_type = "Interface"

  subnet_ids         = local.effective_private_subnet_ids
  security_group_ids = [aws_security_group.monte_carlo_vpce[0].id]

  # Private DNS is not supported for cross-region endpoints
  private_dns_enabled = false

  lifecycle {
    precondition {
      condition     = can(regex("\\.privatelink\\.", var.backend_service_url))
      error_message = "When private_link is configured, backend_service_url must contain '.privatelink.' (e.g. https://artemis.privatelink.getmontecarlo.com)."
    }
  }
}

resource "aws_route53_zone" "monte_carlo_privatelink" {
  count = var.private_link != null ? 1 : 0
  name  = local.private_link_hostname

  vpc {
    vpc_id = local.effective_vpc_id
  }
}

resource "aws_route53_record" "monte_carlo_privatelink" {
  count   = var.private_link != null ? 1 : 0
  zone_id = aws_route53_zone.monte_carlo_privatelink[0].zone_id
  name    = local.private_link_hostname
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.monte_carlo[0].dns_entry[0]["dns_name"]
    zone_id                = aws_vpc_endpoint.monte_carlo[0].dns_entry[0]["hosted_zone_id"]
    evaluate_target_health = true
  }
}
