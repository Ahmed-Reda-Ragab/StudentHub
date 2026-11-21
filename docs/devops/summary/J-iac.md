## J — الـ IaC بالتفصيل (90–93)

### 90 — Terraform بالتفصيل (modules، state، environments)
**الهدف:** تفهم الـ HCL والـ modules والـ `lifecycle` والـ remote state من كود `infra/terraform` نفسه.
**أهم الأوامر:**
```bash
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
terraform state list && terraform state show 'module.alb.aws_lb_listener.http[0]'
terraform state mv 'module.alb.aws_lb_listener.http[0]' 'module.alb.aws_lb_listener.http_external[0]'
terraform force-unlock <LOCK_ID>
terraform apply -replace=module.host.aws_instance.this
terraform test
tflint --recursive --chdir=infra/terraform --config "$PWD/infra/terraform/.tflint.hcl"
```
**التحقق:** `terraform plan -detailed-exitcode` = 0 بعد الـ apply، و `<key>.tflock` بيظهر وقت الـ apply بس · **Gotchas:** • `ignore_changes` = فيه مالك تاني (CI / ASG / CodeDeploy) ومينفعش يبقى conditional • الـ secrets في الـ state حتى مع `sensitive = true` • `-var env=lab2` مبيغيّرش الـ state key · **التكلفة:** مجاني offline؛ stack 20 ≈ $0.03/ساعة

### 91 — Import لموارد الـ Console جوه Terraform + drift
**الهدف:** تدخّل موارد الـ Console (SG، EC2، ECR، SSM، log group) تحت Terraform لحد zero-diff وتفرّق بين الـ drift الحقيقي والمقصود.
**أهم الأوامر:**
```bash
terraform plan -generate-config-out=generated.tf
terraform plan
terraform apply && rm imports.tf
terraform import 'aws_ssm_parameter.app_secret["APP_KEY"]' /student-app/lab/app/APP_KEY
terraform plan -refresh-only
terraform apply -refresh-only
terraform plan -detailed-exitcode; echo "exit=$?"
terraform query -generate-config-out=generated.tf
```
**التحقق:** `Plan: N to import, 0 to add, 0 to change, 0 to destroy` ثم `No changes` بعد الـ apply · **Gotchas:** • الـ import بيتبنّى الـ resource مش القيمة (`value = null # sensitive`) • rule SG اتضافت برّه = الـ plan العادي مش شايفها • weights stack 40 بترجع لو الـ CI غيّرها و `listener_weights_managed_externally = false` · **التكلفة:** الـ import مجاني؛ الموارد بتكلفتها

### 92 — Terraform في الـ CI (plan على PR، approvals، infracost)
**الهدف:** plan read-only على كل PR كـ comment، و apply/destroy بـ dispatch ورا environment `lab` بالـ admin role عن طريق OIDC.
**أهم الأوامر:**
```bash
gh variable set ECS_IMAGE_TAG --body <SHA>
gh pr create --fill && gh pr checks --watch
gh workflow run terraform.yml --ref master -f stack=20-ec2-single -f action=plan
gh workflow run terraform.yml --ref master -f stack=20-ec2-single -f action=apply
gh run watch "$(gh run list --workflow terraform.yml -L 1 --json databaseId --jq '.[0].databaseId')"
gh workflow run terraform.yml --ref master -f stack=20-ec2-single -f action=destroy
checkov -f plan.json --framework terraform_plan
docker run --rm -v "$PWD:/project" -w /project openpolicyagent/conftest test plan.json --policy policy
```
**التحقق:** comment `terraform-plan:<stack>` على الـ PR، و `Apply complete!` في الـ log ومفيش `.tflock` معلّق · **Gotchas:** • الـ admin role بيثق في `environment:lab` بس — قفل الـ environment على main/master (الـ `sub` مفيهوش ref) • الـ CI بيشوف الـ defaults + `TF_VAR_*` بس مش tfvars الـ laptop • ملف الـ plan فيه الـ secrets plain text (خطر كـ artifact) · **التكلفة:** GitHub minutes + تكلفة الـ stack اللي اتعمله apply

### 93 — Ansible بالتفصيل (roles، vault، dynamic inventory)
**الهدف:** تفهم الـ inventory الـ dynamic والـ SSM connection والـ roles والـ variables والـ vault والـ rolling بـ `serial`.
**أهم الأوامر:**
```bash
cd infra/ansible && ansible-galaxy collection install -r requirements.yml
ansible-inventory --graph
ansible role_app -m ansible.builtin.ping -e ssm_bucket_name=$SSM_BUCKET
ansible-playbook playbooks/provision.yml -e ssm_bucket_name=$SSM_BUCKET -e target_hosts=standalone
ansible-playbook playbooks/deploy.yml -e ssm_bucket_name=$SSM_BUCKET -e app_image=$IMG --check --diff
ansible-vault encrypt --vault-id "lab@$HOME/.vault-pass-student-app" inventories/lab/group_vars/all/vault.yml
ansible-playbook playbooks/rolling-asg.yml -e ssm_bucket_name=$SSM_BUCKET -e app_image=$IMG -e "{\"rolling_target_group_arns\": $TG}"
ansible-lint --profile=production
```
**التحقق:** التشغيل التاني `changed=0`، و `/opt/student-app/CURRENT_RELEASE` = الـ image · **Gotchas:** • `group_vars/` بيتقري جنب الـ inventory أو الـ playbook بس • `command`/`shell` بيتعملهم skip في `--check` (الـ probes الـ read-only: `check_mode: false`) • `rolling-asg.yml` بيسيب الـ ASG suspended لو فشل (مقصود) · **التكلفة:** مجاني؛ stack 20 ≈ $0.03/ساعة، stack 40 ≈ $0.08/ساعة
