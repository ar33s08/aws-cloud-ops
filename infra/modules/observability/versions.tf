# The provider contract of the module.
#
# Terraform resolves the address of a provider used by the resources of a
# module through the declarations of the module itself, not through those of
# the caller: a requirement that is only declared in the root of the
# environment makes the implicit provider of the module fall back to the
# default namespace of the registry. The DataDog provider does not live in
# that namespace, so an undeclared requirement fails at init, on the runner,
# with "provider registry.terraform.io not found" — the worst possible moment
# to discover it. The contract is therefore repeated here, at the module that
# owns the resources, exactly as the module author would ship it.
#
# The versions are bounded to one major line on purpose: an operations team
# upgrades a provider through a reviewed pull request, never through an
# unbounded drift of what a fresh runner happens to download that day.
terraform {
  required_version = ">= 1.5, < 2.0"

  required_providers {
    aws = {
      source  = "HashiCorp/aws"
      version = "~> 5.0"
    }

    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.0"
    }
  }
}
