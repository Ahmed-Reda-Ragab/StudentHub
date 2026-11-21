# Golden AMI for the student-app ASG fleet (scenario 43).
#
#   AL2023 (latest) ── Ansible playbooks/provision.yml ──► student-app-lab-<arch>-<timestamp>
#                      (common, docker, cloudwatch_agent, node_exporter)
#
# Immutable infrastructure: hosts are never patched in place - a new AMI is baked, tested, and
# rolled out by replacing instances (stack 40: ami_id + golden_ami = true, then instance refresh).
#
#   cd infra/packer && packer init . && packer build .
#   packer build -var arch=arm64 -var prepull_image=<ecr>/student-app:<sha> -var iam_instance_profile=<profile> .

packer {
  required_version = ">= 1.11.0"

  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.8.4"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1.1.6"
    }
  }
}

locals {
  name          = "${var.project}-${var.env}"
  timestamp     = formatdate("YYYYMMDDhhmmss", timestamp())
  instance_type = var.instance_type != "" ? var.instance_type : (var.arch == "arm64" ? "t4g.small" : "t3.small")
  ansible_dir   = abspath("${path.root}/../ansible")
  deprecate_at  = timeadd(timestamp(), "${var.ami_deprecate_days * 24}h")

  # CONVENTIONS §1 mandatory tags. The AMI and its snapshot carry them, so cost reports and the
  # cleanup of old images (scenario 97) can find them.
  tags = {
    Project   = var.project
    Env       = var.env
    ManagedBy = "packer"
    Scenario  = "43"
    Arch      = var.arch
  }
}

source "amazon-ebs" "app" {
  region          = var.region
  instance_type   = local.instance_type
  ami_name        = "${local.name}-${var.arch}-${local.timestamp}"
  ami_description = "student-app golden AMI: AL2023 ${var.arch} + Docker/compose/buildx + CloudWatch agent + node_exporter"
  deprecate_at    = local.deprecate_at

  source_ami_filter {
    filters = {
      # al2023-ami-2023.* excludes the "minimal" images (al2023-ami-minimal-*), which lack the SSM agent.
      name                = "al2023-ami-2023.*-${var.arch}"
      architecture        = var.arch
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  # IMDSv2 only, for the build instance AND (imds_support) every instance launched from the AMI.
  # Hop limit 1: containers cannot reach the instance credentials (matches modules/asg-app).
  imds_support = "v2.0"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Encrypted root volume => encrypted snapshot => encrypted AMI.
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = var.kms_key_id
    delete_on_termination = true
  }
  encrypt_boot = true
  kms_key_id   = var.kms_key_id

  subnet_id                   = var.subnet_id
  associate_public_ip_address = true
  iam_instance_profile        = var.iam_instance_profile

  communicator  = "ssh"
  ssh_username  = "ec2-user"
  ssh_interface = var.ssh_interface
  # Temporary SG (and key pair) created per build; SSH only from the machine running Packer.
  temporary_security_group_source_public_ip = true
  # Remove Packer's temporary public key from the image.
  ssh_clear_authorized_keys = true

  run_tags        = merge(local.tags, { Name = "${local.name}-packer-build" })
  run_volume_tags = local.tags
  tags            = merge(local.tags, { Name = "${local.name}-${var.arch}-${local.timestamp}", SourceAMI = "{{ .SourceAMI }}", SourceAMIName = "{{ .SourceAMIName }}" })
  snapshot_tags   = merge(local.tags, { Name = "${local.name}-${var.arch}-${local.timestamp}" })
}

build {
  name    = "student-app-golden-ami"
  sources = ["source.amazon-ebs.app"]

  # cloud-init may still be running dnf when SSH comes up; wait so Ansible does not hit the rpm lock.
  # Exit code 2 = "done with recoverable errors", fine for a base image.
  provisioner "shell" {
    inline = ["sudo cloud-init status --wait >/dev/null || [ $? -eq 2 ]"]
  }

  # The same playbook used on live hosts (scenario 21): one definition of a "student-app host".
  # use_proxy = false: Ansible connects straight to the instance with Packer's temporary key
  # (the localhost proxy adapter is slower and breaks scp with OpenSSH 9).
  provisioner "ansible" {
    playbook_file = "${local.ansible_dir}/playbooks/provision.yml"
    galaxy_file   = "${local.ansible_dir}/requirements.yml"
    user          = "ec2-user"
    use_proxy     = false
    groups        = ["role_app"]
    ansible_env_vars = [
      "ANSIBLE_CONFIG=${local.ansible_dir}/ansible.cfg",
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_FORCE_COLOR=1",
    ]
    extra_arguments = [
      "--extra-vars", "env_name=${var.env} aws_region=${var.region}",
    ]
  }

  # Optional: bake the current release's layers into the AMI (faster boot / scale-out).
  # The ASG still runs whatever /student-app/<env>/deploy/<color>/IMAGE_URI says at boot.
  provisioner "shell" {
    environment_vars = [
      "IMAGE=${var.prepull_image}",
      "AWS_REGION=${var.region}",
    ]
    inline = [
      "set -eu",
      "if [ -z \"$IMAGE\" ]; then echo 'prepull_image not set - skipping'; exit 0; fi",
      "aws ecr get-login-password --region \"$AWS_REGION\" | sudo docker login --username AWS --password-stdin \"$${IMAGE%%/*}\"",
      "sudo docker pull \"$IMAGE\"",
      "sudo docker logout \"$${IMAGE%%/*}\"",
    ]
  }

  # Leave no build-instance state in the image: registry credentials, agent file offsets, journal.
  provisioner "shell" {
    inline = [
      "sudo systemctl stop amazon-cloudwatch-agent",
      "sudo rm -rf /opt/aws/amazon-cloudwatch-agent/logs/state/* /root/.docker/config.json",
      "sudo journalctl --rotate && sudo journalctl --vacuum-time=1s",
      "sudo docker image prune -f",
    ]
  }

  # manifest.json -> artifact_id "us-east-1:ami-0abc..." for scripts / terraform -var ami_id=...
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
    custom_data = {
      arch     = var.arch
      ami_name = "${local.name}-${var.arch}-${local.timestamp}"
    }
  }
}
