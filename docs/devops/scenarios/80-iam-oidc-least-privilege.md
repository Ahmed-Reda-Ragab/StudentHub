# 80 — IAM و OIDC و Least privilege و Session Manager

> **الهدف في سطر:** تفهم IAM بعمق (policy evaluation، trust vs permissions، conditions)، تقرا الـ 4 GitHub OIDC roles الحقيقية في الـ bootstrap (ci، deploy، terraform admin متقفل بالـ environment، و plan read-only) وتعرف نقط ضعف كل واحد، الـ instance profiles و الـ ECS roles، Session Manager بدل SSH (من غير بورت 22)، و permission boundaries / SCPs / IAM Access Analyzer — Console مرة و Terraform مرة.
> **المستوى:** Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** مجاني
> **بيعتمد على:** [02](02-aws-account-setup.md) · [30](30-ci-github-actions.md) · **الملفات في الـ repo:** [`bootstrap/github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf) · [`bootstrap/variables.tf`](../../../infra/terraform/bootstrap/variables.tf) · [`bootstrap/README.md`](../../../infra/terraform/bootstrap/README.md) · [`bootstrap/ansible-ssm.tf`](../../../infra/terraform/bootstrap/ansible-ssm.tf) · [`stacks/20-ec2-single/iam.tf`](../../../infra/terraform/stacks/20-ec2-single/iam.tf) · [`stacks/40-ec2-alb-asg/iam.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/iam.tf) · [`modules/ecs-fargate/iam.tf`](../../../infra/terraform/modules/ecs-fargate/iam.tf) · [`modules/fis/main.tf`](../../../infra/terraform/modules/fis/main.tf) · [`modules/ec2-docker-host/main.tf`](../../../infra/terraform/modules/ec2-docker-host/main.tf)

## 1) الفكرة (Concepts)

| المصطلح | المعنى |
|---|---|
| Principal | مين بيطلب: user، role session، service (`ec2.amazonaws.com`)، federated identity (GitHub OIDC) |
| Identity policy | متعلّقة بالـ principal: "يقدر يعمل إيه" |
| Resource policy | متعلّقة بالـ resource (S3 bucket policy، KMS key policy، **trust policy** بتاعة الـ role) |
| Trust policy | مين مسموحله يعمل `sts:AssumeRole*` على الـ role ده |
| Permissions boundary | سقف أقصى على role/user — الصلاحية الفعلية = تقاطع الـ policy مع الـ boundary |
| SCP | سقف على مستوى الـ account في AWS Organizations (حتى root) |
| Session policy | سقف إضافي وقت الـ AssumeRole |
| Condition keys | `aws:SourceAccount`، `kms:ViaService`، `ssm:resourceTag/Project`، `iam:PassedToService`، `ecs:CreateAction`، `aws:ResourceTag/...` |
| Confused deputy | service بيستخدم صلاحيته نيابةً عن حساب تاني — الحل `aws:SourceAccount`/`aws:SourceArn` في الـ trust |
| `iam:PassRole` | الصلاحية إنك "تدّي" role لـ service (task definition، launch template) — أخطر صلاحية بعد `iam:*` |

**الـ evaluation:** default **deny** → أي **explicit Deny** (من أي policy/SCP/boundary) بيكسب → لازم **Allow** صريح في identity أو resource policy، وكمان جوه حدود الـ SCP والـ boundary والـ session policy. يعني الـ allow الفعلي = **تقاطع** كل الطبقات.

## 2) المعمارية (Architecture)

```text
 GitHub Actions job (id-token: write)
   │ JWT: iss=token.actions.githubusercontent.com  aud=sts.amazonaws.com  sub=repo:Ahmed-Reda-Ragab/StudentHub:<ref|environment|pull_request>
   ▼
 STS AssumeRoleWithWebIdentity ── trust: aud = sts.amazonaws.com AND sub StringLike <list>
   ├─ student-app-gha-ci              sub: ref:refs/heads/{main,master}             → ECR push/pull repo student-app
   ├─ student-app-gha-deploy          sub: main/master + environment:{lab,production} → ECS/ASG/ALB/SSM/CodeDeploy (scoped)
   ├─ student-app-gha-terraform       sub: environment:lab بس (terraform_branches=[]) → AdministratorAccess (2h)
   └─ student-app-gha-terraform-plan  sub: pull_request + ref:refs/heads/*          → ReadOnlyAccess + decrypt via SSM/SM

 EC2 instance ── instance profile ── role student-app-lab-ec2-single / student-app-lab-asg-app
   (SSM core, CW agent, ECR pull repo, SSM params /student-app/lab/*, kms:Decrypt via ssm [, S3 backups])
   IMDSv2 required, hop limit 1   ·   مفيش SSH key، مفيش port 22  ──►  aws ssm start-session
 ECS task ── execution role (pull, logs, SSM secrets /student-app/lab/app/*) · task role (ssmmessages for Exec)
 FIS ── student-app-lab-fis (trust fis.amazonaws.com + aws:SourceAccount)
```

## 3) المتطلبات (Prerequisites)

- [ ] حساب AWS بـ IAM Identity Center/admin للـ bootstrap ([02](02-aws-account-setup.md)).
- [ ] `gh` CLI بصلاحية admin على الـ repo.
- [ ] Session Manager plugin للـ AWS CLI ([03](03-workstation-setup.md)).
- الأدوات: `aws`، `terraform`، `gh`، `jq`.

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 الـ OIDC provider و role الـ CI

اتشرحوا خطوة بخطوة في [30 §4](30-ci-github-actions.md). هنا هنعمل الـ **plan role** (read-only) يدوي:

1. **IAM → Roles → Create role → Web identity** → Provider `token.actions.githubusercontent.com` → Audience `sts.amazonaws.com`.
2. Permissions: **ReadOnlyAccess** → Name `student-app-gha-terraform-plan-manual` → Create.
3. **Trust relationships → Edit**:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Sid": "GitHubActionsOIDC",
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
         "StringLike": { "token.actions.githubusercontent.com:sub": [
           "repo:Ahmed-Reda-Ragab/StudentHub:pull_request",
           "repo:Ahmed-Reda-Ragab/StudentHub:ref:refs/heads/*"
         ] }
       }
     }]
   }
   ```
4. **Add permissions → Create inline policy** (`plan-secrets-read`) — `ReadOnlyAccess` مش بيفك SecureStrings ولا بيقرا secrets، والـ plan محتاجهم في الـ refresh:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       { "Sid": "DecryptViaSsmAndSecretsManagerOnly", "Effect": "Allow", "Action": "kms:Decrypt",
         "Resource": "arn:aws:kms:us-east-1:<ACCOUNT_ID>:key/*",
         "Condition": { "StringEquals": { "kms:ViaService": ["ssm.us-east-1.amazonaws.com", "secretsmanager.us-east-1.amazonaws.com"] } } },
       { "Sid": "ReadProjectSecrets", "Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
         "Resource": "arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:student-app*" }
     ]
   }
   ```

### 4.2 Session Manager بدل SSH

1. **EC2 → Instances → `student-app-lab-app` → Connect → Session Manager → Connect** (shell في الـ browser).
2. **Systems Manager → Session Manager → Preferences → Edit**: فعّل **CloudWatch logging** (log group مثلاً `/student-app/lab/ssm-sessions`) و/أو S3 — كل session بقى audit trail (مين، إمتى، إيه اللي اتكتب). وفعّل **KMS encryption** للـ sessions لو محتاج.
3. **EC2 → Security Groups** → اتأكد إن **مفيش** inbound 22 (stack 20: `ssh_cidrs = []` و `key_name = null` افتراضياً).

### 4.3 IAM Access Analyzer

1. **IAM → Access analyzer → Analyzer settings → Create analyzer** → Type **External access** → Zone of trust: **Current account** → Create (مجاني). بيطلّع findings لأي resource مشارك بره الحساب (S3، KMS، IAM roles trust، Secrets Manager، SQS...).
2. (اختياري، مدفوع) **Unused access** analyzer: roles/permissions مش مستخدمة.
3. **Policy generation:** IAM → Roles → `student-app-gha-terraform` → **Generate policy** (على أساس CloudTrail events — محتاج trail) → بيطلّع policy بالـ actions اللي اتستخدمت فعلاً في آخر N يوم. ده الطريق لتضييق الـ admin role.
4. **Policy validation:** وانت بتكتب policy في الـ JSON editor، الـ "Policy validator" تحت بيطلّع warnings/suggestions (نفس `validate-policy` في §5.4).

## 5) الطريقة التانية: as Code

### 5.1 الـ bootstrap OIDC ([`github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf))

الـ provider: `aws_iam_openid_connect_provider.github` (`client_id_list = ["sts.amazonaws.com"]`، من غير thumbprints — AWS بيتحقق من cert GitHub بالـ trusted CAs)، أو `data` لو موجود (`create_github_oidc_provider = false` — provider واحد بس لكل URL في الحساب).

**trust policy واحدة لكل role** (`data.aws_iam_policy_document.trust` for_each)، كلها: `StringEquals aud = sts.amazonaws.com` + `StringLike sub` على list:

| Role | Subjects (من الـ variables) | Permissions | `max_session_duration` |
|---|---|---|---|
| `student-app-gha-ci` | `ci_branches` = `main`، `master` → `repo:…:ref:refs/heads/<b>` | `ecr:GetAuthorizationToken` (`*` — مينفعش يتحدد) + push/pull على repo `student-app` بس | 1h |
| `student-app-gha-deploy` | `deploy_branches` (main/master) + `deploy_environments` (`lab`، `production`) → `environment:<e>` | ECS (register/update/run-task على `student-app-*`، `iam:PassRole` على `role/student-app-lab-*` **بشرط** `iam:PassedToService = ecs-tasks.amazonaws.com`، `ecs:TagResource` بشرط `ecs:CreateAction`)، SSM Run Command **بشرط** `ssm:resourceTag/Project = student-app`، `ssm:StartSession` (Ansible) بنفس الشرط + الـ transfer bucket `student-app-ansible-ssm-<acct>`، params `/student-app/*/deploy/*` (+ `GetParameterHistory` للـ rollback)، ASG refresh/rollback على `student-app-*`، `ModifyListener/Rule` على ALBs `student-app-*`، CodeDeploy، `eks:DescribeCluster`، قراية alarms/metrics/logs | 1h |
| `student-app-gha-terraform` | `terraform_environments` (`lab`) → `environment:lab` بس؛ `terraform_branches` default `[]` | **`AdministratorAccess`** (lab shortcut — مكتوب في الكود ليه وإزاي تضيّقه) | 2h (EKS create/destroy) |
| `student-app-gha-terraform-plan` | `repo:…:pull_request` + `repo:…:ref:refs/heads/*` | `ReadOnlyAccess` + inline `plan-secrets-read` (decrypt عن طريق SSM/Secrets Manager بس، `GetSecretValue` على `secret:student-app*`). الـ plans بتجري بـ `-lock=false` فمش محتاج write على الـ state bucket | 1h |

أشكال الـ `sub` (default GitHub template):

| الحالة | `sub` |
|---|---|
| job من غير `environment:` | `repo:<owner>/<repo>:ref:refs/heads/<branch>` |
| job بـ `environment: <name>` | `repo:<owner>/<repo>:environment:<name>` (**مفيهوش ref**) |
| `pull_request` | `repo:<owner>/<repo>:pull_request` (الـ fork PRs مش بتاخد token أصلاً) |

**نقط ضعف وقرارات لازم تقدر تشرحها في interview:**

1. **الـ admin role = environment-only (اتصلحت):** `terraform_branches` default بقى `[]`، فالـ trust فيه `repo:…:environment:lab` بس. لو حطيت branch (مثلاً `["master"]`)، أي job على الـ branch ده **من غير** `environment: lab` هياخد AdministratorAccess ويتخطى الـ required reviewer — عشان كده متضيفش branches. والـ gate الحقيقي محتاج على الـ environment `lab`: required reviewers + deployment branch policy "protected branches only" (وإلا أي branch يقدر يعلن `environment: lab` ويستنى الموافقة بس).
2. **الـ plan role = "repo write access = secret read access":** أي branch push يقدر ياخده (`ref:refs/heads/*`)، وهو بيقرا الـ state bucket (فيه secrets — [81](81-secrets-management.md)) ويفك SecureStrings. مكتوب في الكود. التخفيف: branch protection + مراجعة مين عنده write، أو plan role بيقرا state بس من غير decrypt (والـ resources الحساسة بـ write-only attributes).
3. **`ecr:GetAuthorizationToken` على `*`** مقبول (مفيش resource-level)، بس الـ push نفسه مقفول على repo واحد.
4. **`AdministratorAccess`** — الطريق للتضييق (comment في الكود): CloudTrail + Access Analyzer **generate policy** من كام apply/destroy → role لكل stack → **permissions boundary** يمنع `iam:*` على roles بره `student-app-*` ويمنع org/account/billing APIs.

```bash
cd infra/terraform/bootstrap
terraform init && terraform plan -out tfplan && terraform apply tfplan
terraform output github_repository_variables
terraform output -json github_repository_variables | jq -r 'to_entries[] | "\(.key) \(.value)"' \
  | while read -r k v; do gh variable set "$k" --body "$v"; done
gh variable list
```

### 5.2 Instance profiles

| Role | Stack | Managed | Inline (`student-app-host` / `student-app-instance`) |
|---|---|---|---|
| `student-app-lab-ec2-single` | 20 | `AmazonSSMManagedInstanceCore`، `CloudWatchAgentServerPolicy` | ECR pull (repo واحد)، `ssm:GetParameter(s)`/`GetParametersByPath` على `/student-app/lab` **و** `/student-app/lab/*` (الـ `ByPath` بيتعمله authorize على الـ path نفسه)، `kms:Decrypt` على `key/*` **بشرط** `kms:ViaService = ssm.<region>.amazonaws.com`، S3 backups (`ListBucket` + `Get/PutObject` — مفيش `Delete`) |
| `student-app-lab-asg-app` | 40 | نفسهم | نفس الـ ECR/SSM/KMS (من غير S3) |

- **ليه `kms:ViaService` مش key ARN؟** الـ SecureStrings على AWS-managed key `aws/ssm` واسمها ممكن متكونش موجودة في حساب جديد لحد أول استخدام؛ الشرط بيقول "decrypt بس لما الطلب جاي عن طريق SSM" — مش هيقدر يفك أي حاجة تانية مباشرة.
- **IMDSv2 + hop limit 1** (الـ asg-app launch template و الـ ec2-docker-host): `http_tokens = "required"` بيمنع SSRF الكلاسيكي (GET بسيط على `169.254.169.254`)، و hop limit 1 بيخلّي الـ containers على bridge network **مش قادرة توصل** للـ instance credentials. التطبيق نفسه مش محتاج AWS credentials خالص — الـ host (user data / `render-env-from-ssm.sh`) هو اللي بيقرا SSM.
- الـ SSH: `ssh_cidrs = []` (الـ ingress rule بتتعمل بس لو فيه CIDRs)، `key_name = null`.

### 5.3 ECS و FIS roles

- **Execution role** (`student-app-lab-ecs-execution`): ECR pull على الـ repo من الـ `image_uri`، `logs:CreateLogStream/PutLogEvents` على الـ log group بتاعه، `ssm:GetParameters` على `/student-app/lab/app/*` **بس**، `kms:Decrypt` via SSM. ده اللي بيحل الـ `secrets` وقت بداية الـ task.
- **Task role** (`student-app-lab-ecs-task`): الـ 4 `ssmmessages:*` بس (ECS Exec) — التطبيق مالوش صلاحيات AWS.
- **Infrastructure role** (native blue/green): `AmazonECSInfrastructureRolePolicyForLoadBalancers`.
- كلهم trust بـ `aws:SourceAccount` (confused-deputy guard). نفس الفكرة في `student-app-lab-fis` ([75](75-chaos-engineering-fis.md)).

### 5.4 Permission boundaries و SCPs و Access Analyzer (مش في الـ repo)

Boundary مقترح للـ terraform role (**مش في الـ repo** — تمرين):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AllowEverythingElse", "Effect": "Allow", "Action": "*", "Resource": "*" },
    { "Sid": "NoIamOutsideProject", "Effect": "Deny",
      "Action": ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:DeleteRole", "iam:UpdateAssumeRolePolicy", "iam:PassRole"],
      "NotResource": ["arn:aws:iam::<ACCOUNT_ID>:role/student-app-*", "arn:aws:iam::<ACCOUNT_ID>:role/aws-service-role/*"] },
    { "Sid": "NoOrgBillingAccount", "Effect": "Deny",
      "Action": ["organizations:*", "account:*", "aws-portal:*", "billing:*", "iam:CreateUser", "iam:CreateAccessKey"],
      "Resource": "*" },
    { "Sid": "KeepTheBoundary", "Effect": "Deny",
      "Action": ["iam:DeleteRolePermissionsBoundary", "iam:PutRolePermissionsBoundary"], "Resource": "*" }
  ]
}
```

SCP (لو الحساب جوه Organization) — أمثلة: deny `cloudtrail:StopLogging`/`DeleteTrail`، deny أي region غير `us-east-1`/`us-west-2` (مع استثناء الـ global services)، deny `iam:CreateAccessKey` على الـ root.

```bash
aws accessanalyzer create-analyzer --analyzer-name student-app-account --type ACCOUNT
aws accessanalyzer list-findings-v2 --analyzer-arn <ANALYZER_ARN> --query 'findings[].[resourceType,resource,status]' --output table
aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY --policy-document file://policy.json \
  --query 'findings[].[findingType,issueCode,learnMoreLink]' --output table
aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::<ACCOUNT_ID>:role/student-app-gha-deploy \
  --action-names ecs:UpdateService iam:CreateRole s3:DeleteBucket \
  --resource-arns 'arn:aws:ecs:us-east-1:<ACCOUNT_ID>:service/student-app-lab/student-app-lab-app' \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output table
```

## 6) الـ Deploy

```bash
# Session Manager (من غير SSH)
aws ssm start-session --target <INSTANCE_ID>
aws ssm start-session --target <INSTANCE_ID> --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'      # Grafana على الـ host
aws ssm send-command --instance-ids <INSTANCE_ID> --document-name AWS-RunShellScript \
  --parameters 'commands=["docker ps --format \"{{.Names}} {{.Image}}\""]' --query 'Command.CommandId' --output text
aws ssm get-command-invocation --command-id <CMD_ID> --instance-id <INSTANCE_ID> --query StandardOutputContent --output text

# ECS Exec (بدل SSH للـ containers)
aws ecs execute-command --cluster student-app-lab --task <TASK_ID> --container app --interactive --command "/bin/sh"
```

على GitHub: `ci.yml` (job `image`) بياخد `id-token: write` **على مستوى الـ job بس**، والـ workflow كله `contents: read`. أي workflow بيستخدم الـ terraform role لازم `environment: lab` ([92](92-terraform-in-ci.md))، والـ deploy role ([32](32-cd-ec2-ecr-ssm.md)، [34](34-environments-approvals-promotion.md)).

## 7) التحقق (Verify)

```bash
for r in ci deploy terraform terraform-plan; do
  echo "== student-app-gha-$r"
  aws iam get-role --role-name student-app-gha-$r --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json
done
aws iam list-attached-role-policies --role-name student-app-gha-terraform-plan
aws iam get-role-policy --role-name student-app-gha-terraform-plan --policy-name plan-secrets-read
aws ec2 describe-instances --filters Name=tag:Project,Values=student-app --query 'Reservations[].Instances[].[InstanceId,MetadataOptions.HttpTokens,MetadataOptions.HttpPutResponseHopLimit,KeyName]' --output table
aws ec2 describe-security-groups --filters Name=tag:Project,Values=student-app --query 'SecurityGroups[].IpPermissions[?ToPort==`22`]'   # لازم فاضي
aws ssm describe-instance-information --query 'InstanceInformationList[].[InstanceId,PingStatus,AgentVersion]' --output table
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر/التعديل | المتوقع |
|---|---|---|
| CI من branch تاني | شغّل job بيعمل assume لـ `AWS_ROLE_ARN` من `devops-lab` | `Not authorized to perform sts:AssumeRoleWithWebIdentity` (الـ sub مش في `ci_branches`) |
| Deploy من غير environment | job على branch feature من غير `environment:` | رفض — الـ deploy role بيقبل main/master أو `environment:{lab,production}` |
| Admin من master من غير environment | job على master بيعمل assume لـ `AWS_TERRAFORM_ROLE_ARN` من غير `environment: lab` | **رفض** (`terraform_branches = []` default) — لو رجّعت `["master"]` في tfvars هينجح ويتخطى الـ reviewer |
| PassRole لـ service غلط | `simulate-principal-policy` بـ `iam:PassRole` و context `iam:PassedToService=ec2.amazonaws.com` | `implicitDeny` |
| Container يوصل IMDS | `docker exec <app> wget -qO- http://169.254.169.254/latest/api/token` (PUT مطلوب أصلاً) | مفيش token (hop limit 1) — التطبيق مالوش credentials |
| شيل `kms:Decrypt` | من الـ instance role | `render-env-from-ssm.sh`: `AccessDeniedException` على الـ SecureStrings |
| SSH | ضيف `ssh_cidrs = ["<IP>/32"]` | الـ rule بتتعمل — وده اللي **مش** عايزه؛ رجّعه `[]` |

## 9) الرجوع (Rollback)

- trust اتكسر → `terraform apply` في الـ bootstrap بيرجّعه (أو Console → Edit trust policy).
- role اتسرّب/اتعمله misuse → شيل الـ trust statement أو امسح الـ role فوراً (مفيش keys تعمل لها rotate — ميزة OIDC)، وبعدين CloudTrail: `aws cloudtrail lookup-events --lookup-attributes AttributeKey=Username,AttributeValue=<SESSION_NAME>`.

## 10) المسح (Teardown) ⚠️

```bash
aws iam delete-role-policy --role-name student-app-gha-terraform-plan-manual --policy-name plan-secrets-read
aws iam detach-role-policy --role-name student-app-gha-terraform-plan-manual --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
aws iam delete-role --role-name student-app-gha-terraform-plan-manual
aws accessanalyzer delete-analyzer --analyzer-name student-app-account      # لو مش عايز تسيبه (External access مجاني)
```

الـ bootstrap roles سيبهم — كل السيناريوهات محتاجاهم.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| IAM، STS، OIDC، Session Manager (shell/port forwarding) | مجاني |
| Access Analyzer — external access | مجاني |
| Access Analyzer — unused access / custom policy checks | مدفوع (per role/user شهرياً و per check) — تقريبي، راجع صفحة الأسعار |
| Session logs في CloudWatch | ingestion عادي (سنتات) |
| CloudTrail (management events، trail واحد) | أول نسخة management events مجانية؛ الـ S3 storage سنتات |

## 12) أسئلة Interview

<details><summary>اشرح الـ IAM policy evaluation في سطور.</summary>

Default deny. أي explicit Deny في أي طبقة (SCP، boundary، identity، resource، session) بيكسب فوراً. بعدها لازم Allow صريح (identity policy، أو resource policy في نفس الحساب)، والـ Allow ده لازم يبقى جوه حدود الـ SCP والـ boundary والـ session policy. Cross-account محتاج Allow من الطرفين.

</details>

<details><summary>إزاي تمنع أي repo تاني على GitHub ياخد الـ role بتاعك؟</summary>

الـ trust policy لازم فيها `aud = sts.amazonaws.com` **و** `sub` محدد بالـ repo والـ branch/environment (`StringLike` على list محددة — مش `repo:*` ولا `repo:<owner>/*`). ولو بتستخدم `environment:` اعرف إن الـ ref بيختفي من الـ sub، فالـ environment لازم يبقى عليه protection rules (reviewers، protected branches). ومتستخدمش `pull_request_target` مع checkout لكود الـ PR.

</details>

<details><summary>ليه `iam:PassRole` خطير وإزاي تقيده؟</summary>

لأن مين يقدر يعمل task definition/launch template بـ role أقوى منه يقدر يشغّل كود بالـ role ده = privilege escalation. التقييد: resource على roles معينة (`role/student-app-lab-*`) + condition `iam:PassedToService` (ECS بس) — ده بالظبط اللي في الـ deploy role.

</details>

<details><summary>Session Manager أحسن من SSH ليه؟</summary>

مفيش inbound port (22 مقفول، والـ agent بيعمل outbound لـ SSM)، مفيش keys تتسرّب أو تتعمل لها rotation، الـ access بـ IAM (MFA، conditions، tags)، كل session متسجلة (CloudWatch/S3) للـ audit، وفيه port forwarding لـ Grafana/DB من غير ما تفتح SG. العيوب: محتاج الـ agent والـ role والـ network للـ SSM endpoints (أو VPC endpoints في private subnets).

</details>

<details><summary>الـ terraform role عليه AdministratorAccess — إزاي تدافع عنه أو تصلحه؟</summary>

الدفاع: الـ blast radius متحكم فيه بالـ trust (branches/environment) والـ plans بـ role read-only، وكتابة least-privilege لكل اللي Terraform بيعمله (VPC، IAM، EKS، RDS...) مشروع لوحده. الإصلاح: CloudTrail + Access Analyzer policy generation من runs حقيقية → role لكل stack → permissions boundary يمنع الـ escalation (IAM بره `student-app-*`، billing/org). والـ trust نفسه في الـ repo بقى environment-only (`terraform_branches = []`) فالـ reviewer على `lab` مش ممكن يتخطى بـ branch.

</details>

<details><summary>إيه confused deputy وإزاي الـ repo بيمنعه؟</summary>

service (ECS/FIS) بياخد role نيابةً عن عميل؛ لو الـ trust بيثق في الـ service principal بس، حساب تاني ممكن يخلي نفس الـ service يستخدم الـ role بتاعك. الحل: `aws:SourceAccount` (أو `aws:SourceArn`) في الـ trust — موجود في الـ ECS roles والـ FIS role.

</details>

## 13) Checklist

- [ ] قريت الـ 4 trust policies وأقدر أقول الـ `sub` بتاع كل واحد
- [ ] عملت الـ plan role يدوي (trust + ReadOnlyAccess + inline) وقارنته بالـ Terraform
- [ ] عملت `simulate-principal-policy` على الـ deploy role وشفت implicitDeny
- [ ] اتأكدت من IMDSv2/hop limit 1 ومفيش port 22
- [ ] دخلت instance بـ Session Manager وفعّلت session logging
- [ ] عملت External access analyzer وقريت الـ findings
- [ ] أقدر أشرح ليه الـ admin role environment-only (`terraform_branches = []`) وليه الـ plan role بيقرا secrets وإزاي أخفف ده
