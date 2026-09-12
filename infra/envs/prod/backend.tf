# This file configures the remote state backend of the production environment.
# The state of the estate lives in an S3 bucket with server-side encryption and is
# locked through a DynamoDB table, which is the idiomatic Terraform shape of a
# team backend: a plan that races with the plan of a peer is refused instead of
# interleaving with it. The bucket and the table are provisioned by the bootstrap
# stack of the platform and not by this directory, so that the state of an
# environment can never be destroyed by the environment that it describes.

terraform {
  backend "s3" {
    bucket         = "acco-platform-terraform-state-prod"
    key            = "envs/prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-locks"

    # The assume of the role is the cross-account path of the bootstrap stack of
    # the platform. The apply of the production environment is the act of the
    # pipeline of Atlantis on a merged pull request and never of a console, which
    # is the posture that the drift programme of the repository depends on.
    role_arn    = "arn:aws:iam::000000000000:role/terraform-state-access-role"
    external_id = "acco-platform-prod"

    # The legacy lock file of a working copy is switched off on purpose: the
    # lock of the team is the Dynamo item of the table above and nothing else.
    use_lock_file = false
  }
}
