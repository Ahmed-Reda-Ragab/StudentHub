# infra/packer — golden AMI (scenario 43)

**Golden AMI / immutable infrastructure:** instead of configuring every instance at boot (slow,
and a boot can fail halfway because a mirror is down), the configuration is baked once into an
image, tested, and every instance starts from it. Servers are never patched in place: a fix = a
new AMI + replacing instances (instance refresh). Boot is faster (scale-out reacts sooner),
every instance is identical, and a bad image is rolled back by pointing at the previous AMI.

```text
AL2023 latest (amazon owner, x86_64|arm64)
  └─ Packer amazon-ebs: temp key pair + temp SG (your IP only), IMDSv2, encrypted gp3 root
       └─ Ansible ../ansible/playbooks/provision.yml   (the SAME playbook live hosts use)
            common · docker (pinned compose/buildx, live-restore) · cloudwatch_agent · node_exporter
       └─ optional: docker pull <prepull_image>        (first boot only pulls changed layers)
       └─ cleanup (registry creds, agent state, journal) → AMI student-app-lab-<arch>-<timestamp>
                                                          (tags Project/Env/ManagedBy=packer/Scenario=43,
                                                           deprecated after 90 days)
```

## Build

Requirements on the machine running Packer (WSL): `packer` >= 1.11, Ansible (see
[../ansible/README.md](../ansible/README.md)), AWS credentials allowed to run the amazon-ebs builder
(EC2 instances/volumes/snapshots/AMIs, temporary key pairs and security groups).

```bash
cd infra/packer
packer init .                       # installs the pinned amazon + ansible plugins
packer fmt -check . && packer validate .
packer build .                                        # x86_64, default VPC, ~8 min, cents
packer build -var arch=arm64 .                        # Graviton image for t4g instances
packer build -var ssh_interface=session_manager \
             -var iam_instance_profile=student-app-lab-asg-app .   # no inbound port at all
packer build -var iam_instance_profile=student-app-lab-asg-app \
             -var prepull_image=<acct>.dkr.ecr.us-east-1.amazonaws.com/student-app:<sha> .

jq -r '.builds[-1].artifact_id' manifest.json         # us-east-1:ami-0abc123...
```

The `student-app-lab-asg-app` instance profile (stack 40) has exactly what a build needs for
`session_manager` (AmazonSSMManagedInstanceCore) and `prepull_image` (ECR pull).

## Use it in stack 40

```bash
AMI=$(jq -r '.builds[-1].artifact_id' infra/packer/manifest.json | cut -d: -f2)
cd infra/terraform/stacks/40-ec2-alb-asg
terraform apply -var ami_id=$AMI -var golden_ami=true    # golden_ami: user data skips the Docker install
```

A new `ami_id` = a new launch template version, and the ASG's `instance_refresh` block rolls the
fleet automatically (with alarm-based rollback, because this time the launch template changed).
The application release is independent of the AMI: instances still read
`/student-app/<env>/deploy/<color>/IMAGE_URI` at boot ([deploy-asg.yml](../../.github/workflows/deploy-asg.yml)).

Keep `root_volume_size` (16) <= the launch template volume (20 in `modules/asg-app`), and `arch`
equal to stack 40's `arch`.

## Cleanup

```bash
aws ec2 describe-images --owners self --filters Name=tag:Project,Values=student-app \
  --query 'Images[].[ImageId,Name,CreationDate]' --output table
aws ec2 deregister-image --image-id ami-...      # then delete its snapshot (describe-snapshots by tag)
```
