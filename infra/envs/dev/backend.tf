# This file configures the remote state backend of the development environment.
# The state of the estate lives in an S3 bucket with server-side encryption and is
# locked through a DynamoDB table, which is the idiomatic Terraform shape of a
# team backend: a plan that races with the plan of a peer is refused instead of
# interleaving with it. The bucket and the table are provisioned by the bootstrap
# stack of the platform and not by this directory, so that the state of an
# environment can never be destroyed by the environment that it describes.

terraform {
  backend "s3" {
    bucket         = "acco-platform-terraform-state-dev"
    key            = "envs/dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-locks"

    # The assume of the role is the cross-account path of the bootstrap stack of
    # the platform; a reviewer who has not the rights of the role still gets a
    # local plan by passing the flag of the backend of the init invocation.
    role_arn    = "arn:aws:iam::000000000000:role/terraform-state-access-role"
    external_id = "acco-platform-dev"

    # The legacy lock file of a working copy is switched off on purpose: the
    # lock of the team is the Dynamo item of the table above and nothing else.
    use_lock_file = false
  }
}
