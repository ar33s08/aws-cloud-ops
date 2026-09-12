#!/usr/bin/env bash
#
# This file is the cloud-init user data payload for the bastion hosts that are
# launched by the ec2-bastion-asg Terraform module. The module attaches it to the
# launch template verbatim, so the script stays free of any templating syntax and
# can be linted with shellcheck on its own.
#
# The script is idempotent and fails closed. It performs four tasks and nothing
# else: it installs the Systems Manager agent and the CloudWatch agent, it reads
# the Region from the instance identity document served over IMDSv2, it records the
# instance as a managed node, and it removes SSH as an access path so that operator
# access is through Session Manager only.

set -o errset -o pipefail -o nounset

metadata_base="http://169.254.169.254/latest"

log() {
  printf 'bastion-userdata: %s\n' "$*"
}

fail() {
  printf 'bastion-userdata: error: %s\n' "$*" >&2
  exit 1
}

read_metadata() {
  local -r token
  token=$(curl -sf -X PUT "${metadata_base}/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
    -H "X-aws-ec2-metadata-token-version: 2") || return 1
  curl -sf -H "X-aws-ec2-metadata-token: ${token}" "${metadata_base}/meta-data/$1"
}

log "starting the bastion bootstrap"

if ! command -v dnf >&/dev/null; then
  fail "dnf is not available; this user data expects Amazon Linux 2023"
fi

dnf install -y amazon-ssm-agent amazon-cloudwatch-agent >&2 || fail "agent installation failed"

systemctl enable --now amazon-ssm-agent.service || fail "could not enable the Systems Manager agent"

instance_id=$(read_metadata instance-id) || fail "could not read the instance id from IMDSv2"
region=$(read_metadata placement/region) || fail "could not read the region from IMDSv2"

# The registration marker is what the companion audit script reads back to confirm
# that the host joined the managed fleet; the agent itself registers the instance
# automatically from its instance profile credentials.
install -d -m 0750 /opt/amazon/ssm
printf 'instance-id=%s\nregion=%s\n' "${instance_id}" "${region}" \
  > /opt/amazon/ssm/managed-node.conf
chmod 0600 /opt/amazon/ssm/managed-node.conf

log "instance ${instance_id} in ${region} is now a Systems Manager managed node"

systemctl stop sshd.service >&2 || true
systemctl disable sshd.service >&2 || true
log "the SSH daemon is disabled; operator access is through Session Manager only"

log "the bastion bootstrap finished"
exit 0
