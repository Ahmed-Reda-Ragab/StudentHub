# infra/ansible — configuration management + deploys for the EC2 scenarios

Scenarios **21** (provision), **22–24** (Recreate / blue-green / canary on one host), **27** (backups),
**33** (CD with Ansible), **43** (golden AMI, run by Packer), **47** (rolling deploy behind the ALB), **93** (deep dive).

```text
inventories/lab/aws_ec2.yml        dynamic inventory: tag:Project=student-app, groups role_app / standalone / in_asg
inventories/lab/hosts.ini.example  same groups, static (no AWS calls; CI syntax-check)
inventories/lab/group_vars/all/    main.yml (app_dir, env_name, ssm_prefix, connection switch) + vault.yml.example
roles/                             common · docker · app · nginx_lb · cloudwatch_agent · node_exporter · mysql_backup
playbooks/                         provision · deploy · bluegreen · canary · rolling-asg · rollback · backup
```

The roles do not re-implement the deploy logic: they copy and run the scripts the rest of the lab
uses (`deploy/ec2/*.sh`, `deploy/ec2/lb/bin/*.sh`, `docker-compose.prod.yml`), so a deploy behaves
the same from Ansible, SSM Run Command or a shell on the box.

## 1. Install (WSL2 Ubuntu)

Ansible does not run on Windows natively; use WSL and clone the repo **inside** the WSL filesystem
(Ansible ignores `ansible.cfg` in world-writable dirs such as `/mnt/c/...`).

```bash
sudo apt-get update && sudo apt-get install -y python3-venv unzip
python3 -m venv ~/.venvs/ansible && source ~/.venvs/ansible/bin/activate
pip install "ansible-core>=2.20,<2.22" "boto3>=1.38" "botocore>=1.38" ansible-lint   # 2.22 needs Python 3.13

# SSM connection needs the Session Manager plugin on the controller
curl -fsSLo /tmp/smp.deb https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb
sudo dpkg -i /tmp/smp.deb && session-manager-plugin --version

cd infra/ansible
ansible-galaxy collection install -r requirements.yml    # amazon.aws, community.aws, community.docker
```

## 2. Inventory test

```bash
aws sts get-caller-identity                 # the inventory uses your normal AWS credentials
ansible-inventory --graph                   # @role_app, @standalone (stack 20), @in_asg (stack 40), @color_blue ...
ansible-inventory --host i-0123456789abcdef0 | jq '{ansible_host, ansible_aws_ssm_instance_id, tags}'
```

Host names are **instance ids**: unique, stable, and what SSM targets. For SSH the inventory sets
`ansible_host` to the public DNS name (private IP if none).

## 3. SSM vs SSH

| | SSM (default, `deploy_connection: ssm`) | SSH (`-e deploy_connection=ssh`) |
|---|---|---|
| Network | outbound 443 only, **no port 22** | port 22 open to you (`ssh_cidrs` in stack 20) |
| Credentials | IAM (`ssm:StartSession`), short-lived | a private key file that never expires |
| Audit | CloudTrail + optional session logs | sshd logs on a box you may have deleted |
| Extra setup | session-manager-plugin + an S3 bucket the **controller** can write (module transfer, presigned URLs — the instance needs no S3 permission) | key pair (`key_name`) |

```bash
SSM_BUCKET=$(terraform -chdir=../terraform/bootstrap output -raw ansible_ssm_bucket)   # 1-day transfer bucket
ansible role_app -m ansible.builtin.ping -e ssm_bucket_name=$SSM_BUCKET                   # SSM
ansible role_app -m ansible.builtin.ping -e deploy_connection=ssh --private-key ~/.ssh/student-app.pem
```

Tip: `export ANSIBLE_EXTRA="-e ssm_bucket_name=$SSM_BUCKET"` and append `$ANSIBLE_EXTRA` to the commands below.

## 4. Playbooks

```bash
IMG=123456789012.dkr.ecr.us-east-1.amazonaws.com/student-app:3f2c1ab   # an immutable SHA tag CI pushed

# 21 / 43 — baseline: packages, Africa/Cairo, 2G swap, sysctl, journald cap, dnf-automatic (security),
#           Docker + pinned compose/buildx (live-restore), CloudWatch agent, node_exporter
ansible-playbook playbooks/provision.yml

# 33 — Recreate deploy on the single host: copy compose + scripts, app.env from SSM, deploy only if
#      CURRENT_RELEASE differs (a second run is a no-op), smoke-check /ready
ansible-playbook playbooks/deploy.yml -e app_image=$IMG
ansible-playbook playbooks/deploy.yml -e app_image=$IMG -e app_env_source=vault --vault-password-file ~/.vault-pass-student-app

# 23 — blue/green on one host (first run = init.sh); 24 — canary with the error-rate gate
ansible-playbook playbooks/bluegreen.yml -e app_image=$IMG
ansible-playbook playbooks/canary.yml -e app_image=$IMG -e nginx_lb_canary_step_seconds=60
ansible-playbook playbooks/canary.yml -e app_image=$IMG \
  -e nginx_lb_slot_env=SRE_FAULT_ERROR_RATE=0.5 -e nginx_lb_canary_expect_abort=true    # drill: must abort
#   (a canary needs traffic: deploy/scripts/probe.sh http://<host>/login 0 0.05 in another terminal)

# rollback: lb stack -> instant nginx switch; Recreate stack -> redeploy PREVIOUS_RELEASE
ansible-playbook playbooks/rollback.yml

# 27 — install the daily 03:00 (Africa/Cairo) timer, back up now, optional restore drill into a scratch DB
BACKUP_BUCKET=$(terraform -chdir=../terraform/stacks/20-ec2-single output -raw backup_bucket)
ansible-playbook playbooks/backup.yml -e backup_bucket=$BACKUP_BUCKET
ansible-playbook playbooks/backup.yml -e backup_bucket=$BACKUP_BUCKET -e backup_restore_drill=true

# 47 — rolling deploy over the ASG fleet: serial 1, drain from the target group, deploy, health-gate
TG=$(terraform -chdir=../terraform/stacks/40-ec2-alb-asg output -json target_group_arns)
ansible-playbook playbooks/rolling-asg.yml -e app_image=$IMG -e "{\"rolling_target_group_arns\": $TG}"
```

Host patterns default to the safe set for each playbook (`role_app:&standalone` for single-host
playbooks, `role_app:&in_asg` for `rolling-asg.yml`); override with `-e target_hosts=...` or `--limit`.

`rolling-asg.yml` runs with **your** credentials: it needs `elasticloadbalancing:RegisterTargets/DeregisterTargets`,
`autoscaling:SuspendProcesses/ResumeProcesses`, `ssm:StartSession` and `ssm:PutParameter` — more than the CI
deploy role is allowed. If it fails midway, the failed instance stays out of the target group and the
ASG processes stay suspended on purpose (frozen for investigation). Resume with
`aws autoscaling resume-processes --auto-scaling-group-name student-app-lab-blue`.

## 5. Secrets: SSM (default) or ansible-vault

Default `app_env_source: ssm` runs `deploy/ec2/render-env-from-ssm.sh` on the host with the instance
profile — nothing secret ever passes through the controller. `app_env_source: vault` renders `app.env`
from `group_vars/all/main.yml` (`app_env_vars`) with secrets from `group_vars/all/vault.yml`; see
[`vault.yml.example`](inventories/lab/group_vars/all/vault.yml.example). Env-file tasks use `no_log`/`diff: false`.

## 6. Lint (what CI runs — `.github/workflows/lint-infra.yml`)

```bash
for pb in playbooks/*.yml; do ansible-playbook --syntax-check -i inventories/lab/hosts.ini.example "$pb"; done
ansible-lint --profile=production
```
