# Plan-level coverage for the identity modes: role/association creation,
# effective-role outputs, and the Helm values merge in irsa mode. All runs plan
# without touching real infrastructure: providers are mocked at the file level,
# and the one run that nests the module (whose own providers aren't covered by
# those mocks) overrides its resources instead. No AWS/EKS credentials needed.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  # The eks module parses the caller identity ARN, so the mock must return a
  # valid ARN, and IAM policy document mocks must return valid JSON for the
  # roles/policies that consume them.
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:role/test"
      user_id    = "ARIDEXAMPLE"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Mock\",\"Action\":\"sts:AssumeRole\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"eks.amazonaws.com\"}}]}"
    }
  }

  # issuer_arn flows into aws_eks_access_entry.principal_arn, which carries an
  # ARN validator — a mock placeholder would be rejected the same way.
  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:role/test"
    }
  }

  # The root module base64-decodes the cluster CA, and the same_root_agent_role
  # fixture nests the module, so its own kubernetes provider runs unmocked and
  # (kubernetes provider >= 3.2) rejects anything but a real PEM. The value is a
  # throwaway self-signed certificate (CN=mock-eks-ca; private key discarded).
  mock_data "aws_eks_cluster" {
    defaults = {
      endpoint              = "https://test-cluster.eks.us-east-1.amazonaws.com"
      certificate_authority = [{ data = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJnekNDQVNtZ0F3SUJBZ0lVSGJYQnkxY2E4WXg1MHg5ZW5LbUhuMjJLSjFzd0NnWUlLb1pJemowRUF3SXcKRmpFVU1CSUdBMVVFQXd3TGJXOWpheTFsYTNNdFkyRXdJQmNOTWpZd09USXpNVEkwTkRFM1doZ1BNakV5TmpBNApNekF4TWpRME1UZGFNQll4RkRBU0JnTlZCQU1NQzIxdlkyc3RaV3R6TFdOaE1Ga3dFd1lIS29aSXpqMENBUVlJCktvWkl6ajBEQVFjRFFnQUUzRzFSR3hQN0tsemptYW8wakJNZ05vTitDQ1VPMnYzNUpqWHI3eXd2am5NTERxOE0KbU1idDF6QXZ1UnNqSkd0Y1prSm1ka2RZaGt3bUM2QWZZM3hQTTZOVE1GRXdIUVlEVlIwT0JCWUVGTHdER1hpMgptZnF3N09KMVJUNzNQUWI4NFpON01COEdBMVVkSXdRWU1CYUFGTHdER1hpMm1mcXc3T0oxUlQ3M1BRYjg0Wk43Ck1BOEdBMVVkRXdFQi93UUZNQU1CQWY4d0NnWUlLb1pJemowRUF3SURTQUF3UlFJaEFMMUpuZU43WG5ubEZsWTIKczFtcVovZzUrNHBRalEwaWxvUmUybjdXaXNQZUFpQjlqV1Q0SmVpcjEycTBEbEIyMHl0a3NBQ1Mrdmpma29qQwpyLzdBUiszRlBBPT0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=" }]
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/test" }] }]
    }
  }
}

mock_provider "random" {}
mock_provider "tls" {}
mock_provider "time" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  backend_service_url = "https://api.montecarlodata.com"

  # Satisfies the mcd_secrets_access_role precondition that requires token
  # credentials when the module creates the token secret (dummy values; runs
  # only plan against mocked providers).
  token_credentials = {
    mcd_id    = "test-id"
    mcd_token = "test-token"
  }

  # Pinned to an existing cluster: module-created cluster names are computed
  # (unknown at plan), which would make name-based assertions unevaluable.
  cluster = {
    create                = false
    existing_cluster_name = "test-cluster"
  }

  # Pinned so plans never depend on the mocked aws_availability_zones data
  # source's generated value.
  networking = {
    availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }

  helm = {
    chart_version = "0.0.2"
  }
}

run "default_pod_identity_unchanged" {
  command = plan

  assert {
    condition     = length(aws_eks_pod_identity_association.agent_association) == 1
    error_message = "Default configuration must create the agent Pod Identity association."
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.eso_association) == 1
    error_message = "Default configuration must create the ESO Pod Identity association."
  }

  assert {
    condition     = length(aws_iam_role.agent) == 1
    error_message = "Default configuration must create the module-managed agent role."
  }

  assert {
    condition     = endswith(aws_iam_role.agent[0].name, "-pod-identity")
    error_message = "Agent role name must end with -pod-identity in pod_identity mode."
  }

  assert {
    condition     = output.agent_service_account_name == "mcd-agent-service-account"
    error_message = "agent_service_account_name must report the agent's service account name."
  }
}

run "irsa" {
  command = plan

  variables {
    identity = {
      mode = "irsa"
    }
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.agent_association) == 0
    error_message = "irsa mode must not create the agent Pod Identity association."
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.eso_association) == 0
    error_message = "irsa mode must not create the ESO Pod Identity association."
  }

  assert {
    condition     = length(aws_iam_role.agent) == 1 && endswith(aws_iam_role.agent[0].name, "-irsa")
    error_message = "irsa mode must create the agent role with an -irsa name suffix."
  }

  assert {
    condition     = length(aws_iam_role.eso_role) == 1
    error_message = "The module-installed ESO must still get its role in irsa mode."
  }
}

run "existing_eso_pod_identity" {
  command = plan

  # Pre-existing ESO consumed in the default pod_identity mode: the module must
  # create neither its own ESO role nor the ESO association.
  variables {
    identity = {
      existing_eso_role_arn = "arn:aws:iam::123456789012:role/external-secrets"
    }
    helm = {
      chart_version                     = "0.0.2"
      install_external_secrets_operator = false
    }
  }

  assert {
    condition     = length(aws_iam_role.eso_role) == 0
    error_message = "The module ESO role must be skipped when a pre-existing ESO role is supplied."
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.eso_association) == 0
    error_message = "The ESO Pod Identity association must be skipped when a pre-existing ESO role is supplied."
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.agent_association) == 1
    error_message = "The agent Pod Identity association must still be created."
  }

  assert {
    condition     = output.eso_role_arn == "arn:aws:iam::123456789012:role/external-secrets"
    error_message = "eso_role_arn must be the effective role — the pre-existing ESO's ARN, not null."
  }
}

run "byo_agent_role" {
  command = plan

  variables {
    identity = {
      existing_agent_role_arn = "arn:aws:iam::123456789012:role/my-agent"
      existing_eso_role_arn   = "arn:aws:iam::123456789012:role/external-secrets"
    }
    storage = {
      create_bucket        = false
      existing_bucket_name = "my-bucket"
    }
    helm = {
      chart_version                     = "0.0.2"
      install_external_secrets_operator = false
    }
  }

  assert {
    condition     = length(aws_iam_role.agent) == 0
    error_message = "No module-managed agent role may be created when identity.existing_agent_role_arn is supplied."
  }

  assert {
    condition     = length(aws_iam_role_policy.mcd_agent_service_s3_policy) == 0
    error_message = "The S3 inline policy must be skipped when the customer brings the agent role."
  }

  assert {
    condition     = output.agent_role_arn == "arn:aws:iam::123456789012:role/my-agent"
    error_message = "agent_role_arn must equal identity.existing_agent_role_arn when supplied."
  }

  assert {
    condition     = output.pod_identity_role_arn == "arn:aws:iam::123456789012:role/my-agent"
    error_message = "pod_identity_role_arn (deprecated alias) must mirror agent_role_arn."
  }
}

run "irsa_with_module_created_cluster" {
  command = plan

  # module.eks[0].oidc_provider_arn is computed — unknown at plan time — so
  # this run pins down that the IRSA path plans cleanly against it (trust
  # policies and the Helm annotation reference it without forcing it).
  variables {
    identity = {
      mode = "irsa"
    }
    cluster = {
      create = true
    }
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.agent_association) == 0
    error_message = "irsa mode must not create the agent Pod Identity association on a module-created cluster."
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.eso_association) == 0
    error_message = "irsa mode must not create the ESO Pod Identity association on a module-created cluster."
  }

  assert {
    condition     = length(aws_iam_role.agent) == 1 && length(aws_iam_role.eso_role) == 1
    error_message = "irsa mode on a module-created cluster must still create both module-managed roles."
  }
}

run "irsa_with_both_existing_roles" {
  command = plan

  # Both roles customer-supplied: no OIDC provider is in play, so the lookup
  # data source must be skipped (no iam:ListOpenIDConnectProviders permission
  # needed) and the eagerly-evaluated trust policies fall back to the
  # "no-oidc-provider" sentinel without ever being attached.
  variables {
    identity = {
      mode                    = "irsa"
      existing_agent_role_arn = "arn:aws:iam::123456789012:role/my-agent"
      existing_eso_role_arn   = "arn:aws:iam::123456789012:role/external-secrets"
    }
    storage = {
      create_bucket        = false
      existing_bucket_name = "my-bucket"
    }
    helm = {
      chart_version                     = "0.0.2"
      install_external_secrets_operator = false
    }
  }

  assert {
    condition     = length(data.aws_iam_openid_connect_provider.existing) == 0
    error_message = "No OIDC provider lookup may happen when both roles are customer-supplied."
  }

  assert {
    condition     = local.oidc_provider_id == "no-oidc-provider"
    error_message = "The OIDC provider id must fall back to the sentinel when no provider is in play."
  }

  assert {
    condition     = length(aws_iam_role.agent) == 0 && length(aws_iam_role.eso_role) == 0
    error_message = "No module-managed roles may be created when both roles are customer-supplied."
  }

  assert {
    condition     = output.agent_role_arn == "arn:aws:iam::123456789012:role/my-agent" && output.eso_role_arn == "arn:aws:iam::123456789012:role/external-secrets"
    error_message = "Both role outputs must report the customer-supplied ARNs."
  }
}

run "custom_service_account_annotations_merge_with_irsa" {
  command = plan

  variables {
    identity = {
      mode = "irsa"
    }
    custom_values = {
      serviceAccount = {
        # The chart only reads serviceAccount.annotations — the name is
        # hardcoded in its templates — so annotations are what must merge.
        annotations = {
          "example.com/annotation" = "value"
        }
      }
    }
  }

  # The IRSA role-arn annotation is re-applied after custom_values with a
  # nested merge, so both it and the caller's own annotations must survive
  # into the rendered values. Key presence is asserted (not the value) because
  # the role ARN is computed and unknown at plan time.
  assert {
    condition     = contains(keys(local.helm_values.serviceAccount.annotations), "eks.amazonaws.com/role-arn")
    error_message = "The eks.amazonaws.com/role-arn annotation must survive merging custom_values into the agent Helm values."
  }

  assert {
    condition     = try(local.helm_values.serviceAccount.annotations["example.com/annotation"], null) == "value"
    error_message = "The caller's own serviceAccount.annotations must survive the module re-applying the IRSA annotation."
  }
}

run "byo_agent_role_created_in_same_root" {
  command = plan

  # Same-root role: .arn is unknown at plan time, so create_agent_role = false must
  # keep every count known. Planning successfully IS the assertion — outputs derived
  # from the unknown ARN can't be compared at plan time.
  module {
    source = "./tests/fixtures/same_root_agent_role"
  }

  variables {
    create_agent_role = false
  }

  # The fixture nests the module, so its own helm/kubernetes providers run
  # unmocked (the file-level mock_provider blocks don't reach them). Override
  # their resources so the plan stays offline instead of reaching a real
  # cluster or fetching the chart from oci://registry-1.docker.io.
  override_resource {
    target = module.mcd_agent.helm_release.external_secrets
  }

  override_resource {
    target = module.mcd_agent.helm_release.mcd_agent
  }

  override_resource {
    target = module.mcd_agent.kubernetes_namespace_v1.mcd_agent
  }
}

run "byo_agent_role_with_explicit_create_flag" {
  command = plan

  # The explicit flag with a known ARN must behave exactly like the inferred
  # byo_agent_role run.
  variables {
    identity = {
      create_agent_role       = false
      existing_agent_role_arn = "arn:aws:iam::123456789012:role/my-agent"
      existing_eso_role_arn   = "arn:aws:iam::123456789012:role/external-secrets"
    }
    storage = {
      create_bucket        = false
      existing_bucket_name = "my-bucket"
    }
    helm = {
      chart_version                     = "0.0.2"
      install_external_secrets_operator = false
    }
  }

  assert {
    condition     = length(aws_iam_role.agent) == 0 && length(aws_iam_role_policy.mcd_agent_service_s3_policy) == 0
    error_message = "identity.create_agent_role = false must create no agent role and no S3 policy."
  }

  assert {
    condition     = output.agent_role_arn == "arn:aws:iam::123456789012:role/my-agent"
    error_message = "agent_role_arn must equal identity.existing_agent_role_arn when create_agent_role = false."
  }
}

run "creates_agent_role_with_explicit_create_flag" {
  command = plan

  # The explicit flag with no ARN must behave exactly like the inferred
  # default-create run.
  variables {
    identity = {
      create_agent_role = true
    }
  }

  assert {
    condition     = length(aws_iam_role.agent) == 1
    error_message = "identity.create_agent_role = true must create the module-managed agent role."
  }

  assert {
    condition     = length(aws_iam_role_policy.mcd_agent_service_s3_policy) == 1
    error_message = "identity.create_agent_role = true must create the S3 inline policy."
  }
}
