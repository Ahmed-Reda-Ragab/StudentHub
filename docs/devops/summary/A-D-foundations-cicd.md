<!-- Summary cards for scenarios 02, 21, 27, 31–37 (assembled by docs/devops/pdf/assemble-summary.mjs) -->

### 02 — تجهيز حساب AWS (MFA، Identity Center، Budgets، CLI، bootstrap)

**الهدف:** root مقفول بـ MFA، دخول يومي بـ Identity Center و `aws configure sso`، Budgets/anomaly/billing alarm، وبعدين bootstrap (state bucket، OIDC roles، ECR، CodeConnections) وتوصيل GitHub.

**أهم الأوامر:**
```bash
aws configure sso && aws sso login --sso-session student && export AWS_PROFILE=student-lab-admin
cd infra/terraform/bootstrap && terraform init && terraform apply
terraform output -raw backend_hcl > ../backend.hcl     # + uncomment backend "s3" في versions.tf
terraform init -migrate-state -backend-config=../backend.hcl && terraform plan   # No changes
terraform output -json github_repository_variables | jq -r 'to_entries[] | "\(.key) \(.value)"' \
  | while read -r k v; do gh variable set "$k" --body "$v"; done
aws codeconnections get-connection --connection-arn "$(terraform output -raw codeconnections_arn)" --query Connection.ConnectionStatus
```
**التحقق:** `aws sts get-caller-identity` = `AWSReservedSSO_*` · الـ connection `AVAILABLE` · `gh variable list` فيها 8 قيم · **Gotchas:** • Identity Center لازم **organization instance** (الـ account instance مافيهوش permission sets) • الـ CodeConnections بيتعمل PENDING ومحتاج handshake في الـ Console • required reviewers على الـ private repos محتاجة Enterprise · **التكلفة:** < $1/شهر

### 21 — نفس الحاجة بـ Terraform + Ansible

**الهدف:** stack `20-ec2-single` (VPC + EC2 + EIP + IAM + backups bucket + SSM params بـ `APP_KEY` متولّد) ثم Ansible: dynamic inventory و `provision.yml` و `deploy.yml` idempotent.

**أهم الأوامر:**
```bash
cd infra/terraform/stacks/20-ec2-single && terraform init -backend-config=../../backend.hcl && terraform apply
$(terraform output -raw ssm_start_session)
cd ../../../ansible && ansible-galaxy collection install -r requirements.yml
export ANSIBLE_EXTRA="-e ssm_bucket_name=$(terraform -chdir=../terraform/bootstrap output -raw ansible_ssm_bucket)"
ansible-inventory --graph && ansible role_app -m ping $ANSIBLE_EXTRA
ansible-playbook playbooks/provision.yml $ANSIBLE_EXTRA
ansible-playbook playbooks/deploy.yml -e app_image=<acct>.dkr.ecr.us-east-1.amazonaws.com/student-app:<sha> $ANSIBLE_EXTRA   # مرتين → changed=0
```
**التحقق:** `curl http://<EIP>/ready` = version الـ tag · التشغيل التاني `changed=0` · **Gotchas:** • الـ secrets في الـ Terraform state • `ansible.cfg` بيتجاهل في `/mnt/c` • `key_name` على instance شغال = replacement · **التكلفة:** ~$0.03/ساعة

### 27 — Backup لـ MySQL على S3 + تجربة restore

**الهدف:** `mysqldump --single-transaction | gzip | aws s3 cp -` يومي بـ systemd timer، retention بالـ lifecycle، و restore drill بيقيس RPO/RTO.

**أهم الأوامر:**
```bash
BUCKET=$(terraform -chdir=../terraform/stacks/20-ec2-single output -raw backup_bucket)
ansible-playbook playbooks/backup.yml -e backup_bucket=$BUCKET $ANSIBLE_EXTRA
ansible-playbook playbooks/backup.yml -e backup_bucket=$BUCKET -e backup_restore_drill=true $ANSIBLE_EXTRA
systemctl list-timers student-app-mysql-backup.timer && journalctl -u student-app-mysql-backup.service -n 20
aws s3 ls s3://$BUCKET/mysql/ | grep -v '\.partial$' | tail -3   # .partial = backup فشل/شغال
aws s3 cp s3://$BUCKET/<key>.sql.gz - | gunzip | tail -1        # -- Dump completed on ...
BACKUP_BUCKET=$BUCKET /opt/student-app/backup-mysql-to-s3.sh restore s3://$BUCKET/<key>.sql.gz
```
**التحقق:** الـ drill: `Restore drill passed` · RPO = الفشل − آخر backup · RTO = لحد `/ready` 200 · **Gotchas:** • السكريبت بيرفع على `.partial` وبيعمل `s3 mv` بعد النجاح (الـ host يقدر يمسح `*.partial` بس، مش الـ dumps) • الـ bucket بيتمسح مع الـ stack (`force_destroy`) • الـ rollback للكود مايرجّعش الـ schema · **التكلفة:** سنتات

### 31 — CD → EC2 بـ SSH + build على السيرفر (الطريقة القديمة)

**الهدف:** تشغّل `deploy-ec2-ssh-build.yml` (ssh → checkout → build → Recreate) وتشرح ليه anti-pattern وإزاي تعمله بأمان لو مضطر.

**أهم الأوامر:**
```bash
aws ec2 create-key-pair --key-name student-app-lab --key-type ed25519 --query KeyMaterial --output text > ~/.ssh/student-app-lab.pem
# terraform.tfvars (stack 20): ssh_cidrs = ["0.0.0.0/0"]  key_name = "student-app-lab"  → apply
gh secret set EC2_SSH_PRIVATE_KEY < ~/.ssh/student-app-lab.pem
gh variable set EC2_HOST --body <EIP> && gh variable set EC2_SSH_KNOWN_HOSTS --body "<EIP> ssh-ed25519 AAAA..."
gh workflow run deploy-ec2-ssh-build.yml --ref devops-lab -f ref=devops-lab
```
**التحقق:** الـ summary فيه downtime بالثواني و `version` = الـ commit · **Gotchas:** • الـ host key من SSM مش `ssh-keyscan` (TOFU) • `key_name` = replacement للـ instance • الـ rollback = rebuild (مش نفس الـ bytes) · **التكلفة:** نفس 20 (`t3.small` إجباري للـ build)

### 32 — CD → EC2 بـ ECR + SSM Run Command

**الهدف:** `deploy-ec2-ssm.yml`: tag → digest، سكريبتات الـ commit بـ `git archive`، `ssm send-command` + polling، و CD اختياري بعد الـ CI.

**أهم الأوامر:**
```bash
gh variable set EC2_INSTANCE_ID --body "$(terraform output -raw instance_id)"
gh variable set APP_URL --env lab --body "$(terraform output -raw app_url)"
gh workflow run deploy-ec2-ssm.yml --ref devops-lab -f image_tag=<sha7>
gh variable set EC2_CONTINUOUS_DEPLOY --body true         # opt-in: deploy بعد كل CI ناجح على master
aws ssm list-commands --max-results 1 --query 'Commands[0].[Status,Comment]'
aws logs tail /student-app/lab/ssm-deploy --since 30m
```
**التحقق:** `CURRENT_RELEASE` فيه `@sha256:` و `/ready` version = الـ tag · **Gotchas:** • الـ deploy files لازم committed (git archive) • `workflow_run`/`dispatch` محتاجين الـ workflow على الـ default branch • الـ SendCommand مقفول على tag `Project=student-app` · **التكلفة:** SSM مجاني، `t3.micro` يكفي

### 33 — CD → EC2 بـ Ansible

**الهدف:** `deploy-ec2-ansible.yml`: الـ runner controller، aws_ec2 inventory، connection SSM عبر transfer bucket، deploy idempotent.

**أهم الأوامر:**
```bash
gh variable set ANSIBLE_SSM_BUCKET --body "$(terraform -chdir=infra/terraform/bootstrap output -raw ansible_ssm_bucket)"
gh workflow run deploy-ec2-ansible.yml --ref devops-lab -f image_tag=<sha7> -f connection=ssm -f check_mode=true
gh workflow run deploy-ec2-ansible.yml --ref devops-lab -f image_tag=<sha7> -f connection=ssm   # مرتين → changed=0
gh run view <RUN_ID> --log | grep -A3 "PLAY RECAP"
aws ssm describe-sessions --state History --max-results 5
```
**التحقق:** الـ summary فيه PLAY RECAP بـ `changed=0` في التشغيل التاني · **Gotchas:** • الـ instance مش محتاج S3 permission (presigned URLs) • `role_app:&standalone` بيطابق prod و lab لو الاتنين موجودين → زوّد `:&env_lab` • check mode بيتخطّى الـ `command` tasks · **التكلفة:** ~$0 فوق 20

### 34 — Environments و approvals و promotion و rollback

**الهدف:** environments `lab`/`production` بـ reviewers و wait timer و branch policy، `release-promote.yml` بنفس الـ digest + release tag، rollback بالـ tag اللي قبله، و DORA.

**أهم الأوامر:**
```bash
gh api -X PUT repos/Ahmed-Reda-Ragab/StudentHub/environments/production --input env-production.json
gh variable set ENV_NAME --env production --body production          # لازم = اسم الـ environment (الـ guard)
gh variable set EC2_INSTANCE_ID --env production --body <PROD_IID>     # instance عليه Env=production + APP_URL
gh workflow run release-promote.yml --ref master -f image_tag=<sha7>   # Actions → Review deployments → Approve
gh workflow run deploy-ec2-canary.yml --ref master -f image_tag=<sha7> -f slot_env=SRE_FAULT_ERROR_RATE=0.5 -f expect_abort=true
git tag -l 'release-*' --sort=-creatordate | head -3
git for-each-ref 'refs/tags/release-*' --format='%(creatordate:format:%G-W%V)' | sort | uniq -c   # deployment frequency
```
**التحقق:** نفس الـ digest في lab و prod + tag `release-<date>-<sha>` · **Gotchas:** • الـ guard بيرفض environment غير lab من غير `ENV_NAME` = اسمه أو instance الـ `Env` tag بتاعه مختلف — بس `APP_URL` ناقص لسه بيعمل fallback لـ lab • الـ OIDC `sub` بتاع environment مافيهوش branch → branch policy إجباري • "Protected branches only" محتاجة branch محمي فعلاً · **التكلفة:** مجاني (+ host production: stack 20 workspace بـ `env=production`)

### 35 — AWS CodeBuild (buildspec، webhook، GitHub Actions runners)

**الهدف:** stack 35 (projects `ci`/`image`/`gha-runner`، role لكل project)، الـ buildspecs سطر بسطر، privileged + layer cache، و runner لـ GitHub Actions.

**أهم الأوامر:**
```bash
cd infra/terraform/stacks/35-codebuild && cp terraform.tfvars.example terraform.tfvars   # codeconnections_arn
terraform init -backend-config=../../backend.hcl && terraform apply
aws codebuild start-build --project-name student-app-image --source-version master
aws logs tail /aws/codebuild/student-app-image --follow
aws codebuild batch-get-builds --ids <BUILD_ID> --query 'builds[0].buildStatus'
# workflow: runs-on: codebuild-student-app-gha-runner-${{ github.run_id }}-${{ github.run_attempt }}
```
**التحقق:** report group `student-app-ci-phpunit` + commit status على GitHub + image في ECR (أو `already exists ... skipping`) · **Gotchas:** • `post_build` بيجري حتى لو الـ build فشل (guard) • Docker Hub rate limits على IPs مشتركة • الـ runner job بياخد الـ project role تلقائي · **التكلفة:** ~$0.005/دقيقة (small)، مفيش idle

### 36 — AWS CodePipeline

**الهدف:** stack 36: V2 pipeline (Source CodeConnections → Build → [Approve] → [Migrate] + ECS/CodeDeployToECS/CodeBuild) لخدمة stack 50.

**أهم الأوامر:**
```bash
cd infra/terraform/stacks/36-codepipeline && cp terraform.tfvars.example terraform.tfvars   # codeconnections_arn, deploy_mode
terraform -chdir=../50-ecs-fargate output -json pipeline_inputs > stack50.auto.tfvars.json   # gitignored
terraform init -backend-config=../../backend.hcl && terraform apply
aws codepipeline start-pipeline-execution --name student-app-lab-pipeline
aws codepipeline get-pipeline-state --name student-app-lab-pipeline --query 'stageStates[].[stageName,latestExecution.status]'
terraform destroy && cd ../50-ecs-fargate && terraform destroy    # 36 قبل 50
```
**التحقق:** كل الـ stages Succeeded و `/ready` على الـ ALB بالـ version الجديدة · **Gotchas:** • الـ ECS action بياخد task def الخدمة الحالية مش آخر revision Terraform • أعد توليد `stack50.auto.tfvars.json` بعد `CODE_DEPLOY` • docs-only commits مبتشغّلش الـ pipeline · **التكلفة:** ~$0.002/action-minute + CodeBuild (~$0.05/release)

### 37 — AWS CodeDeploy لـ EC2/ASG

**الهدف:** CodeDeploy in-place على ASG stack 40 (`codedeploy.tf`: revision bucket + app + group بـ traffic control و alarm)، revision فيها image reference + hooks، و rollback على الفشل/الـ alarms.

**أهم الأوامر:**
```bash
echo 'codedeploy_enabled = true' >> terraform.tfvars && terraform apply     # stack 40: agent + bucket + app/group (instance refresh)
REV_BUCKET=$(terraform output -json codedeploy | jq -r .revision_bucket); terraform output -json codedeploy | jq -r .release
DIR=$(deploy/codedeploy/ec2/package-revision.sh <acct>.dkr.ecr.us-east-1.amazonaws.com/student-app:<sha7>)
aws deploy push --application-name student-app-lab-ec2 --s3-location s3://$REV_BUCKET/codedeploy/student-app-<sha7>.zip --source "$DIR"
aws deploy create-deployment --application-name student-app-lab-ec2 --deployment-group-name student-app-lab-ec2 \
  --s3-location bucket=$REV_BUCKET,key=codedeploy/student-app-<sha7>.zip,bundleType=zip
aws deploy wait deployment-successful --deployment-id <ID>
```
**التحقق:** lifecycle events كلها Succeeded و `/ready` version = الـ tag على كل الـ instances · **Gotchas:** • مفيش GitHub workflow، والـ deploy role مالوش S3 write على الـ revision bucket (CLI/Console بس) • الـ rollback بيرجّع الكود مش الـ SSM config • CodeDeploy مابيحدّثش `/student-app/lab/deploy/blue/IMAGE_URI` (scale-out بيبوت القديم لحد الـ launch hook) · **التكلفة:** CodeDeploy على EC2 مجاني؛ stack 40 ~$0.08/ساعة
