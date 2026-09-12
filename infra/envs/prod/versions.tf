# This file pins the toolchain of the production environment of the platform: the
# minimum of the Terraform language that the modules of the estate rely on (the
# cross-variable validation of the bastion module needs the 1.4 series, and the
# platform standard is the 1.5 series), the 5.x provider line of the AWS provider,
# and the 3.x provider line of the DataDog provider. The lock file of the module
# is committed to the repository so that the review of a plan and the apply of the
# release resolve the same provider builds.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    datadog = {
      source  = "Datadog/datadog"
      version = "~> 3.0"
    }
  }
}
