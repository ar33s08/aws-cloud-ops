# This file declares the provider configuration of the production environment of
# the platform. The provider of the AWS plane carries the default tags of the
# estate, so that every resource that the plan of the environment creates carries
# the owner and the project of the platform without a hand-typed tag; the DataDog
# plane reads its credentials from the environment of the runner of the pipeline
# and never from the state of Terraform.
#
# The variables of the environment live in variables.tf, the shared profile that a
# plan of the directory addresses with the flag of the file of Terraform; the
# reviewed profile of the production environment is in it: three Availability
# Zones, the classes of the memory optimised family, and the multi-Zone database.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Owner     = var.owner_tag
      Project   = var.project_tag
      ManagedBy = "terraform"
      PartOf    = "aws-cloud-ops"
    }
  }

  # The assume of the role is the cross-account path of the pipeline of Atlantis:
  # a plan of the estate that runs as the identity of a human is itself the drift
  # that the toolkit of the repository exists to catch, so the role is a required
  # input and the session that it mints stays short by the policy of the trust.
  assume_role {
    role_arn    = var.deployment_role_arn
    external_id = var.project_tag
  }
}

provider "datadog" {
  # The credentials of the plane of the vendor arrive through the environment of
  # the runner of the pipeline and never through a variable of Terraform, so
  # that a key of the DataDog can not end up in the state file of the estate.
  api_key = var.datadog_api_key
  app_key = var.datadog_app_key
}
