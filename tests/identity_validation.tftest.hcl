# Input-validation coverage for the identity variable. Runs plan against fully
# mocked providers (no AWS/EKS credentials needed); expect_failures runs assert
# the validations reject the combination, and the success runs pin the
# deliberate escape hatches.

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

  # Pinned so plans never depend on the mocked aws_availability_zones data
  # source's generated value.
  networking = {
    availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }

  helm = {
    chart_version = "0.0.2"
  }
}

run "rejects_unknown_mode" {
  command = plan

  variables {
    identity = {
      mode = "podidentity"
    }
  }

  expect_failures = [var.identity]
}

run "rejects_eso_role_arn_with_eso_install" {
  command = plan

  # Default helm installs the module's own ESO, so also supplying a
  # pre-existing ESO role is contradictory.
  variables {
    identity = {
      existing_eso_role_arn = "arn:aws:iam::123456789012:role/eso"
    }
  }

  expect_failures = [var.identity]
}

run "requires_eso_role_arn_in_irsa_with_existing_eso" {
  command = plan

  variables {
    identity = {
      mode = "irsa"
    }
    helm = {
      chart_version                     = "0.0.2"
      install_external_secrets_operator = false
    }
  }

  expect_failures = [var.identity]
}

run "requires_eso_role_arn_in_pod_identity_with_existing_eso" {
  command = plan

  # The default mode must not leave the hijack reachable either: the module's
  # Pod Identity association would rebind the shared external-secrets service
  # account away from the identity the pre-existing operator already uses.
  variables {
    helm = {
      chart_version                     = "0.0.2"
      install_external_secrets_operator = false
    }
  }

  expect_failures = [var.identity]
}

run "accepts_irsa_with_eso_role_arn" {
  command = plan

  variables {
    identity = {
      mode                  = "irsa"
      existing_eso_role_arn = "arn:aws:iam::123456789012:role/eso"
    }
    helm = {
      chart_version                     = "0.0.2"
      install_external_secrets_operator = false
    }
  }
}

run "waives_eso_role_when_agent_not_deployed" {
  command = plan

  # deploy_agent = false is the deliberate escape hatch: with no agent
  # SecretStore to serve, existing_eso_role_arn is not required.
  variables {
    identity = {
      mode = "irsa"
    }
    helm = {
      chart_version                     = "0.0.2"
      install_external_secrets_operator = false
      deploy_agent                      = false
    }
  }
}

run "rejects_malformed_eso_role_arn" {
  command = plan

  # install_external_secrets_operator = false keeps this from tripping the
  # "ESO role conflicts with module-installed ESO" validation instead.
  variables {
    identity = {
      existing_eso_role_arn = "my-eso-role"
    }
    helm = {
      chart_version                     = "0.0.2"
      install_external_secrets_operator = false
    }
  }

  expect_failures = [var.identity]
}

run "rejects_malformed_agent_role_arn" {
  command = plan

  # existing_bucket_name is set so this trips the ARN shape validation and not
  # the existing-bucket requirement.
  variables {
    identity = {
      existing_agent_role_arn = "my-agent-role"
    }
    storage = {
      create_bucket        = false
      existing_bucket_name = "bucket"
    }
  }

  expect_failures = [var.identity]
}

run "requires_existing_bucket_with_byo_agent_role" {
  command = plan

  # A pre-authored role cannot be scoped to the module-created bucket (its name
  # embeds a random ID), so storage.existing_bucket_name must accompany it.
  variables {
    identity = {
      existing_agent_role_arn = "arn:aws:iam::123456789012:role/agent"
    }
  }

  expect_failures = [var.identity]
}

run "rejects_oidc_provider_arn_in_pod_identity_mode" {
  command = plan

  # oidc_provider_arn only applies in irsa mode; in pod_identity mode it would
  # be silently ignored, so it is rejected.
  variables {
    identity = {
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/ABC123"
    }
  }

  expect_failures = [var.identity]
}

run "rejects_create_agent_role_false_without_role_arn" {
  command = plan

  # The agent needs a role: declining the module's without supplying one fails.
  variables {
    identity = {
      create_agent_role = false
    }
    storage = {
      create_bucket        = false
      existing_bucket_name = "my-bucket"
    }
  }

  expect_failures = [var.identity]
}

run "rejects_create_agent_role_true_with_role_arn" {
  command = plan

  # Contradictory: the module would create a role while a supplied one is
  # silently ignored.
  variables {
    identity = {
      create_agent_role       = true
      existing_agent_role_arn = "arn:aws:iam::123456789012:role/agent"
    }
    storage = {
      create_bucket        = false
      existing_bucket_name = "my-bucket"
    }
  }

  expect_failures = [var.identity]
}

run "requires_existing_bucket_with_create_agent_role_false" {
  command = plan

  # The bucket requirement is keyed on the same expression as
  # local.creating_agent_role, so this run pins it via the explicit flag rather
  # than relying on existing_agent_role_arn, isolating this one validation.
  variables {
    identity = {
      create_agent_role       = false
      existing_agent_role_arn = "arn:aws:iam::123456789012:role/agent"
    }
  }

  expect_failures = [var.identity]
}
