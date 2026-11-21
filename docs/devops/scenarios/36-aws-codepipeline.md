# 36 — AWS CodePipeline

> **الهدف في سطر:** تبني CD AWS-native لخدمة ECS بتاعة [51](51-ecs-fargate-terraform.md) بـ stack 36: pipeline **V2** (Source بـ CodeConnections → Build بـ CodeBuild → [Approve] → Deploy)، بتلات deploy modes (`ecs` / `codedeploy-ecs` / `codebuild`)، migration step قبل الـ deploy، triggers بـ filters (branches/file paths/tags)، وتعرف تبنيها من الـ Console، وتعمل destroy بالترتيب الصح (36 قبل 50).
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** ~$0 idle + سنتات لكل release (فوق تكلفة stack 50)
> **بيعتمد على:** [02](02-aws-account-setup.md) (CodeConnections) · [35](35-aws-codebuild.md) · [51 — ECS Fargate بـ Terraform](51-ecs-fargate-terraform.md) · **الملفات في الـ repo:** [`infra/terraform/stacks/36-codepipeline/`](../../../infra/terraform/stacks/36-codepipeline/) ([`main.tf`](../../../infra/terraform/stacks/36-codepipeline/main.tf) · [`variables.tf`](../../../infra/terraform/stacks/36-codepipeline/variables.tf) · [`outputs.tf`](../../../infra/terraform/stacks/36-codepipeline/outputs.tf) · [`README.md`](../../../infra/terraform/stacks/36-codepipeline/README.md)) · [`infra/terraform/modules/codepipeline/`](../../../infra/terraform/modules/codepipeline/main.tf) · [`deploy/codebuild/buildspec-build.yml`](../../../deploy/codebuild/buildspec-build.yml) · [`deploy/codebuild/buildspec-deploy-ecs.yml`](../../../deploy/codebuild/buildspec-deploy-ecs.yml) · [`deploy/ecs/render-taskdef.sh`](../../../deploy/ecs/render-taskdef.sh) · [`deploy/ecs/README.md`](../../../deploy/ecs/README.md)

## 1) الفكرة (Concepts)

**CodePipeline** = orchestrator: بيوصّل **stages** ورا بعض، كل stage فيها **actions** (source/build/approval/deploy/invoke)، وبينقلوا بينهم **artifacts** (zip في S3) و **variables**. هو نفسه مبيبنيش ولا بيعمل deploy — بيندَه CodeBuild و ECS و CodeDeploy.

| المصطلح | المعنى |
|---|---|
| Stage / Action | الـ actions جوه الـ stage بتجري بالتوازي إلا لو `run_order` مختلف |
| Artifact store | S3 bucket الـ pipeline بيحط فيه `source_output` و `build_output` |
| Namespace / variables | `#{SourceVariables.CommitId}`، `#{BuildVariables.IMAGE_URI}` (من `exported-variables` في الـ buildspec) |
| **V1 vs V2** | V2: **triggers بـ filters** (push على branches/tags/file paths، pull requests)، pipeline-level variables، execution modes، stage rollback، وتسعير بالـ action-minute (V1: $1/pipeline/شهر) |
| Execution mode | `SUPERSEDED` (الجديد بيلغي القديم المستني)، **`QUEUED`** (بالترتيب، deploy شغال مايتقطعش)، `PARALLEL` |
| `imagedefinitions.json` | input الـ ECS deploy action: `[{"name":"app","imageUri":"..."}]` |
| `imageDetail.json` | input الـ CodeDeployToECS: `{"ImageURI":"..."}` بيتحط مكان `<IMAGE1_NAME>` في `taskdef.json` |
| CodeConnections | الـ GitHub App connection (`CodeStarSourceConnection` provider) |

| القرار | اخترنا | البديل | ليه |
|---|---|---|---|
| النوع | V2 | V1 | triggers بفلاتر، والتسعير أرخص لـ pipeline قليل الاستخدام |
| Execution mode | `QUEUED` | `SUPERSEDED` | deploy شغال (migration) مايتقطعش، وكل commit بيتعمله deploy بالترتيب |
| الـ projects | CodeBuild projects خاصة بالـ pipeline (`CODEPIPELINE` source) | استخدام projects stack 35 | stack 36 مستقل عن 35 (destroy أي واحد مايبوّظش التاني) |
| Migrations | action `Migrate` (CodeBuild) قبل الـ deploy | جوه الـ container عند الـ boot | مرة واحدة لكل release، قبل ما الكود الجديد ياخد traffic (CONVENTIONS §2) |
| الـ inputs من stack 50 | ملف `stack50.auto.tfvars.json` متولّد | `terraform_remote_state` | الـ stacks مبتقراش state بعض (lifecycles منفصلة) |

## 2) المعمارية (Architecture)

```text
 trigger (V2): push على branch (master) — ignore لو الـ files كلها docs/** أو **/*.md
 pipeline student-app-lab-pipeline · V2 · QUEUED · artifacts s3://student-app-lab-pipeline-artifacts-<acct> (SSE-KMS aws/s3, 14d, TLS-only)
 ┌ Source ───────────────┐  ┌ Build ─────────────────────────────┐  ┌ Approve ─────────┐  ┌ Deploy ─────────────────────────────────────┐
 │ CodeStarSourceConn.   │  │ Image (CodeBuild)                  │  │ (require_approval)│  │ deploy_mode = ecs:                           │
 │ GitHub StudentHub     │─►│ student-app-lab-pipeline-image     │─►│ Manual "Promote" │─►│  1 Migrate (CodeBuild …-pipeline-deploy,     │
 │ ns SourceVariables    │  │ buildspec-build.yml (privileged)   │  │ CustomData: Deploy│  │    DEPLOY_STEP=migrate)                      │
 │ → source_output       │  │ ns BuildVariables (IMAGE_URI/TAG)  │  │ #{BuildVariables. │  │  2 ECS (imagedefinitions.json)               │
 └───────────────────────┘  │ → build_output: imagedefinitions,  │  │  IMAGE_URI} ...   │  │ deploy_mode = codedeploy-ecs:                │
                            │   imageDetail, taskdef, appspec    │  │ [SNS notify]      │  │  1 Migrate  2 CodeDeployToECS (taskdef.json  │
                            └────────────────────────────────────┘  └───────────────────┘  │    + appspec.yaml + <IMAGE1_NAME>)           │
                                                                                            │ deploy_mode = codebuild:                     │
                                                                                            │  1 MigrateAndDeploy (DEPLOY_STEP=all:        │
                                                                                            │    register → migrate → update-service → wait)│
                                                                                            └──────────────────────┬───────────────────────┘
                                                                                                                   ▼
                                                                         ECS service student-app-lab-app (stack 50) ── ALB
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 50 متعمله apply ([51](51-ecs-fargate-terraform.md)) والخدمة شغالة. لـ `codedeploy-ecs`: stack 50 بـ `deployment_controller = "CODE_DEPLOY"` ([54](54-ecs-codedeploy-bluegreen-canary.md)).
- [ ] CodeConnections **AVAILABLE** ([02 §5.7](02-aws-account-setup.md)).
- [ ] ECR + صلاحية push (الـ image project بيعمل push لو الـ tag مش موجود).
- [ ] الـ branch اللي هيشغّل الـ pipeline (افتراضي `master`) فيه `deploy/codebuild/` و `deploy/ecs/`.

## 4) الطريقة الأولى: AWS Console (يدوي)

> ⚠️ ابنيها بإيدك باسم مختلف (`student-app-lab-pipeline-console`) أو قبل/بعد الـ Terraform — مش الاتنين على نفس الخدمة في نفس الوقت (الاتنين هيعملوا deploy).

1. **CodePipeline → Pipelines → Create pipeline** → **Build custom pipeline** → Next.
2. **Pipeline settings:** Name `student-app-lab-pipeline-console` · Execution mode **Queued** · Service role **New service role** · (Advanced: Artifact store default location، Encryption key **Default AWS Managed Key**) → Next.
3. **Source:** Source provider **GitHub (via GitHub App)** → Connection `student-app-github` → Repository `Ahmed-Reda-Ragab/StudentHub` → Default branch `master` → Output artifact format **CodePipeline default** → **Trigger:** "Specify filter" → Event type **Push** → Filter type **Branch** → include `master` → (add filter) **File path** → exclude `docs/**`، `**/*.md` → Next.
4. **Build:** **Other build providers → AWS CodeBuild** → **Create project** (بتفتح نافذة):
   - Name `student-app-lab-pipeline-image-console` · Managed image Ubuntu Standard `aws/codebuild/standard:8.0` · ✅ **Privileged** · Env vars `ECR_REPO=student-app`، `ENV_NAME=lab`، `AWS_ACCOUNT_ID=<ACCOUNT_ID>` · Buildspec file `deploy/codebuild/buildspec-build.yml` → **Continue to CodePipeline**.
   - **Variable namespace:** `BuildVariables` · Output artifact `build_output` → Next.
   - بعدين ضيف ECR push على الـ service role بتاع الـ project (زي [35 §4.2](35-aws-codebuild.md)).
5. **Test stage:** Skip.
6. **Deploy:** Deploy provider **Amazon ECS** → Cluster `student-app-lab` → Service `student-app-lab-app` → Image definitions file `imagedefinitions.json` → Deployment timeout 30 → Next → **Create pipeline**.
7. أول execution بيبدأ تلقائي. شوف كل stage → **View details** → logs الـ CodeBuild.
8. **Approval (اختياري):** **Edit → + Add stage** بين Build و Deploy → `Approve` → **Add action group** → Action provider **Manual approval** → (SNS topic اختياري) → Done → **Save**.
9. **Migration (اختياري):** في stage Deploy → **Edit stage → Add action group قبل ECS** → CodeBuild project بـ `buildspec-deploy-ecs.yml` + Input artifacts `SourceArtifact` + `build_output` (Primary source = الـ source) + Environment variable `DEPLOY_STEP=migrate` (والـ project محتاج صلاحيات ECS RunTask/PassRole — شوف `data.aws_iam_policy_document.deploy` في [`main.tf`](../../../infra/terraform/stacks/36-codepipeline/main.tf)).

من صفحة الـ pipeline: **Release change** (تشغيل يدوي)، **Stop execution** (Stop and wait / Stop and abandon)، **Retry** على stage فاشل، **History** (كل execution بالـ commit والـ trigger)، و في V2 **Start rollback** على stage لآخر execution ناجح.

## 5) الطريقة التانية: Infrastructure as Code (stack 36)

### 5.1 الـ variables

| Variable | الافتراضي | المعنى |
|---|---|---|
| `codeconnections_arn` | (required) | من الـ bootstrap |
| `branch` | `master` | الـ branch اللي بيشغّل الـ trigger |
| `deploy_mode` | `ecs` | `ecs` \| `codedeploy-ecs` \| `codebuild` (الـ module بيعمل validation) |
| `run_migrations` | `true` | action `Migrate` قبل الـ deploy (في `ecs`/`codedeploy-ecs`؛ `codebuild` بيعمل migrate جوه) |
| `require_approval` / `approval_sns_topic_arn` | `false` / `null` | stage `Approve` + إشعار SNS |
| `taskdef_source` | `repo` | `codedeploy-ecs`: `repo` = `deploy/ecs/taskdef.json` · `live` = آخر revision من الـ family (بيدّي الـ image project `ecs:DescribeTaskDefinition`) |
| `ecr_repository_name` / `build_image` | `student-app` / `standard:8.0` | |
| `ecs_cluster_name`, `ecs_service_name`, `task_family`, `task_execution_role_arn`, `task_role_arn`, `app_log_group_arn`, `codedeploy_app_name`, `codedeploy_deployment_group_name` | `null` | من stack 50 (§5.2)؛ `null` = الأسماء اللي stack 50 بيشتقها (`student-app-lab`، `student-app-lab-app`، roles `student-app-lab-ecs-{execution,task}`، `/ecs/student-app-lab/app`) |

### 5.2 `stack50.auto.tfvars.json` (مش copy/paste)

```bash
cd infra/terraform/stacks/36-codepipeline
cp terraform.tfvars.example terraform.tfvars
sed -i "s|^codeconnections_arn = .*|codeconnections_arn = \"$(terraform -chdir=../../bootstrap output -raw codeconnections_arn)\"|" terraform.tfvars
terraform -chdir=../50-ecs-fargate output -json pipeline_inputs > stack50.auto.tfvars.json
cat stack50.auto.tfvars.json        # ecs_cluster_name, ecs_service_name, task_family, task_execution_role_arn, task_role_arn,
                                    # app_log_group_arn, codedeploy_app_name, codedeploy_deployment_group_name (null لو مش CODE_DEPLOY)
git check-ignore -v stack50.auto.tfvars.json     # .gitignore: **/*.auto.tfvars.json
```

- Terraform بيحمّل أي `*.auto.tfvars.json` تلقائي، والـ keys = أسماء variables الـ stack ده بالظبط (الـ output `pipeline_inputs` في stack 50 معمول كده عن قصد).
- **gitignored** لأنه فيه ARNs بالـ account ID ومتولّد. ولو شغّلت الـ stack من [`terraform.yml`](../../../.github/workflows/terraform.yml) الملف مش هيبقى موجود → الـ defaults.
- **أعد توليده** بعد ما تغيّر stack 50 لـ `CODE_DEPLOY` (عشان `codedeploy_*` يبقى ليهم قيم).

### 5.3 الـ apply

```bash
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan
terraform apply tfplan              # V2 pipeline بيبدأ execution أول ما يتعمل
terraform output
# pipeline_name, pipeline_console_url, start_command, artifact_bucket, codebuild_projects, deploy_mode
```

### 5.4 اللي بيتعمل (module + stack)

| Resource | التفاصيل |
|---|---|
| Artifact bucket `student-app-lab-pipeline-artifacts-<acct>` | `force_destroy = true`، public block، `BucketOwnerEnforced`، **SSE-KMS بالـ `aws/s3` managed key** + bucket key (طلبات KMS أقل)، lifecycle 14 يوم، policy TLS-only |
| Pipeline role `student-app-lab-pipeline-codepipeline` | S3 على الـ bucket، `UseConnection`، `codebuild:StartBuild/BatchGetBuilds/StopBuild` على الـ projects بتاعته بس، وحسب الـ mode: ECS service واحد + `RegisterTaskDefinition` + `PassRole` (للـ `ecs-tasks.amazonaws.com` بس) / CodeDeploy على app/group واحد / `sns:Publish` |
| CodeBuild `student-app-lab-pipeline-image` | `CODEPIPELINE` source، `buildspec-build.yml`، privileged، Docker layer cache، ECR push، env `TASKDEF_SOURCE`/`TASK_FAMILY` |
| CodeBuild `student-app-lab-pipeline-deploy` | (لو `run_migrations` أو `codebuild` mode) `buildspec-deploy-ecs.yml`، timeout 60، extra policy: service واحد، `RunTask` على الـ family **بشرط** `ecs:cluster` = الـ cluster ده، `PassRole` للـ task roles، `logs:GetLogEvents` للـ migration logs |
| Pipeline | V2، `QUEUED`، trigger push على `branch` مع `file_paths.excludes = ["docs/**","**/*.md"]`، stages Source → Build → [Approve] → Deploy |

### 5.5 الـ deploy modes

| `deploy_mode` | الـ Deploy stage | الخدمة لازم | يناسب |
|---|---|---|---|
| `ecs` (36) | `Migrate` (run_order 1) → `ECS` action (run_order 2) بـ `imagedefinitions.json`، `DeploymentTimeout` 30 | `deployment_controller = ECS` (rolling أو native B/G/linear/canary — [55](55-ecs-native-bluegreen-linear-canary.md)) | الأبسط |
| `codedeploy-ecs` (58) | `Migrate` → `CodeDeployToECS` (`taskdef.json` + `appspec.yaml` + `Image1ContainerName = IMAGE1_NAME`) | `CODE_DEPLOY` + الـ codedeploy module في stack 50 | blue/green/canary بـ CodeDeploy ([54](54-ecs-codedeploy-bluegreen-canary.md)) |
| `codebuild` (36b) | action واحد `MigrateAndDeploy` (`DEPLOY_STEP=all`) | `ECS` | تحكّم كامل في الـ rollout (render live taskdef → register → migrate → update-service → poll لحد `COMPLETED`/`FAILED`) |

> ⚠️ **نقطة دقيقة من الـ README:** الـ `ECS` deploy action بياخد الـ task definition **الحالية للخدمة** ويغيّر الـ image بس — مش آخر revision Terraform عمله. فلو غيّرت env في Terraform (revision جديدة)، مش هتوصل للخدمة عن طريق الـ pipeline إلا بعد deploy بـ `codebuild` mode أو GitHub Actions (اللي بيستخدموا `render-taskdef.sh live` = آخر revision + image جديدة).

### 5.6 الـ Migration step

`buildspec-deploy-ecs.yml` بـ `DEPLOY_STEP=migrate`: الـ image من `imageDetail.json` في `CODEBUILD_SRC_DIR_build_output` (الـ secondary input)، يرفض `:latest`، الـ family من الخدمة، `render-taskdef.sh live` → `register-task-definition` → `run-migrations.sh` (one-off task، يفشل لو exit ≠ 0) → exit 0 من غير `update-service`. **لو الـ migration فشلت، الـ ECS action مابيجريش** → الخدمة فاضلة على النسخة القديمة. والشرط إن الـ migrations backward compatible ([95](95-zero-downtime-db-migrations.md)) لأن الكود القديم بيخدم على الـ schema الجديدة لحد ما الـ rollout يخلص.

## 6) الـ Deploy

### 6.1 تشغيل ومتابعة

```bash
P=$(terraform output -raw pipeline_name)                       # student-app-lab-pipeline
aws codepipeline start-pipeline-execution --name "$P"
aws codepipeline list-pipeline-executions --pipeline-name "$P" --max-items 3 \
  --query 'pipelineExecutionSummaries[].{id:pipelineExecutionId,status:status,trigger:trigger.triggerType,commit:sourceRevisions[0].revisionId}'
aws codepipeline get-pipeline-state --name "$P" \
  --query 'stageStates[].{stage:stageName,status:latestExecution.status}' --output table
```

### 6.2 الموافقة من الـ CLI (`require_approval = true`)

```bash
TOKEN=$(aws codepipeline get-pipeline-state --name "$P" \
  --query "stageStates[?stageName=='Approve'].actionStates[0].latestExecution.token" --output text)
aws codepipeline put-approval-result --pipeline-name "$P" --stage-name Approve --action-name Promote \
  --result "summary=smoke ok on lab,status=Approved" --token "$TOKEN"
```

### 6.3 Triggers و filters (V2)

الـ module بيعمل trigger واحد: push على `var.branch` مع excludes للـ docs. أمثلة triggers تانية (V2) — بالـ Console (**Edit → Edit: Source → Trigger**) أو بالـ JSON:

```json
"triggers": [{
  "providerType": "CodeStarSourceConnection",
  "gitConfiguration": {
    "sourceActionName": "Source",
    "push": [
      { "tags": { "includes": ["release-*"] } },
      { "branches": { "includes": ["master"] }, "filePaths": { "excludes": ["docs/**", "**/*.md"] } }
    ]
  }
}]
```

```bash
aws codepipeline get-pipeline --name "$P" --query 'pipeline.triggers'
# للتجربة: get-pipeline > p.json → عدّل .pipeline.triggers → aws codepipeline update-pipeline --cli-input-json file://p.json
```

> ⚠️ أي تعديل بالـ Console/CLI = drift: `terraform apply` الجاي هيرجّعه. الـ module مش بيعرض tags trigger كـ variable — لو محتاجه دايم، ده تعديل في الـ module ([90](90-terraform-deep-dive.md)).

> 💡 **Tag trigger** مفيد لـ promotion: `master` → lab تلقائي، و tag `release-*` → pipeline تاني لـ production (نفس فكرة [34](34-environments-approvals-promotion.md) بس AWS-native).

## 7) التحقق (Verify)

```bash
URL=$(terraform -chdir=../50-ecs-fargate output -raw app_url)
curl -s "$URL/ready" | jq '{status, version}'                     # version = أول 7 حروف من آخر commit على master
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app \
  --query 'services[0].{td:taskDefinition,deployments:deployments[].{status:status,rollout:rolloutState,td:taskDefinition}}'
aws codebuild list-builds-for-project --project-name student-app-lab-pipeline-deploy --max-items 1
aws s3 ls "s3://$(terraform output -raw artifact_bucket)/" --recursive | tail -5
```

المفروض: كل الـ stages `Succeeded`، task definition revision جديدة بالـ image، و `/ready` بالـ version الجديدة.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Docs-only commit | `git commit -m "docs" docs/...` + push على master | مفيش execution (file path exclude) |
| Migration بتفشل | branch فيه migration بايظة → merge | `Migrate` FAILED → `ECS` مابيبدأش → الخدمة على القديم |
| Container مابيقومش | release بـ `SRE_FAULT_BOOT_FAIL=true` (بنفس طريقة [53](53-ecs-rolling-circuit-breaker.md)) | الـ ECS circuit breaker بيعمل rollback → الـ ECS action FAILED |
| Reject | `put-approval-result ... status=Rejected` | الـ execution Failed عند Approve — Deploy مابيجريش |
| Connection PENDING | استخدم connection جديد من غير handshake | Source FAILED (`connection is not available`) |
| `QUEUED` | ادفع 3 commits ورا بعض بسرعة | 3 executions بالترتيب؛ قارن بـ `SUPERSEDED` (اللي في النص بيتلغي) |
| Destroy بالترتيب الغلط | `terraform destroy` في 50 الأول | الـ pipeline يفضل موجود ويفشل في كل push (الخدمة مش موجودة)، والـ executions بتصرف دقائق CodeBuild على الفاضي — **36 قبل 50** |

## 9) الرجوع (Rollback)

```bash
# V2: رجّع stage الـ Deploy لآخر execution ناجح (بيعيد نشر نفس الـ artifacts القديمة)
PREV=$(aws codepipeline list-pipeline-executions --pipeline-name "$P" \
  --query "pipelineExecutionSummaries[?status=='Succeeded'] | [1].pipelineExecutionId" --output text)
aws codepipeline rollback-stage --pipeline-name "$P" --stage-name Deploy --target-pipeline-execution-id "$PREV"

# بديل: git revert + push (execution جديد) — أو deploy-ecs.yml بـ tag قديم ([58])
# Stop لـ execution شغال:
aws codepipeline stop-pipeline-execution --pipeline-name "$P" --pipeline-execution-id <ID> --abandon --reason "bad release"
```

> ⚠️ الـ migrations مبترجعش. ومع `codedeploy-ecs`، CodeDeploy نفسه بيعمل auto-rollback على الفشل/الـ alarms ([54](54-ecs-codedeploy-bluegreen-canary.md)).

## 10) المسح (Teardown) ⚠️

**الترتيب:** 36 → 35 → 50 ([`infra/terraform/README.md`](../../../infra/terraform/README.md) "Destroy order").

```bash
cd infra/terraform/stacks/36-codepipeline
terraform destroy                     # الـ pipeline + الـ bucket (force_destroy) + الـ CodeBuild projects + roles
rm -f stack50.auto.tfvars.json
cd ../50-ecs-fargate && terraform destroy
aws codepipeline list-pipelines --query 'pipelines[].name'
aws s3 ls | grep pipeline-artifacts
```

لو عملت pipeline من الـ Console: **Delete pipeline**، وامسح الـ CodeBuild project، والـ service roles (`AWSCodePipelineServiceRole-*`، `codebuild-*-service-role`)، والـ artifact bucket (`codepipeline-us-east-1-*`).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1، تقريبي — راجع صفحة الأسعار) |
|---|---|
| CodePipeline V2 | ~$0.002 لكل action-execution-minute (100 دقيقة مجانية/شهر)؛ مفيش idle |
| CodeBuild small | ~$0.005/دقيقة (image ~6 دقايق، migrate ~2) |
| S3 artifacts + KMS (`aws/s3`) | سنتات (bucket key بيقلل طلبات KMS) |
| **لكل release** | **≈ $0.05** (فوق stack 50: ALB + Fargate + RDS) |

## 12) أسئلة Interview

<details><summary>CodePipeline V1 مقابل V2؟</summary>

V2: triggers بفلاتر (branches/tags/file paths/PR events) بدل "أي push على الـ branch"، pipeline-level variables، execution modes (`QUEUED`/`PARALLEL` بالإضافة لـ `SUPERSEDED`)، stage rollback، وتسعير بالدقيقة بدل $1/pipeline/شهر. V1 لسه موجود بس الجديد كله V2.

</details>

<details><summary>`QUEUED` ولا `SUPERSEDED` لـ deploy pipeline؟</summary>

`SUPERSEDED` بيوفّر وقت (أحدث commit بس بيوصل) بس ممكن execution يتلغي وهو في مرحلة حساسة لو الـ stage مش atomic. `QUEUED` بيضمن إن كل execution بيكمّل بالترتيب ومحدش بيقطع deploy/migration شغال — أبطأ مع commits كتير، بس أوضح في الـ audit. مع migrations اخترنا `QUEUED`.

</details>

<details><summary>`imagedefinitions.json` مقابل `imageDetail.json`؟</summary>

الأول للـ ECS standard deploy action: قايمة container name → image، والـ action بيعمل copy للـ task definition الحالية ويغيّر الـ image. التاني للـ CodeDeployToECS: image واحدة بتتحط مكان placeholder (`<IMAGE1_NAME>`) في `taskdef.json` template، ومعاه `appspec.yaml`. الـ buildspec بيطلّع الاتنين عشان أي mode يشتغل.

</details>

<details><summary>ليه الـ migrations action منفصل قبل الـ deploy؟</summary>

عشان تجري **مرة واحدة** لكل release (مش مع كل task عند الـ boot)، بالـ image الجديدة، وقبل ما الكود الجديد ياخد traffic؛ ولو فشلت، الـ deploy مابيبدأش. الشرط: migrations backward compatible (expand/contract) لأن الكود القديم بيخدم على الـ schema الجديدة أثناء الـ rollout، وعشان الـ rollback يبقى ممكن.

</details>

<details><summary>CodePipeline مقابل GitHub Actions للـ CD؟</summary>

CodePipeline: AWS-native، IAM roles بدل OIDC، approvals و audit في AWS، cross-account deploys بـ roles و KMS، ومتكامل مع CodeDeploy. بس الـ ecosystem أضعف، الـ debugging أبطأ، و YAML/Terraform أكتر. GitHub Actions: مرن وسريع والـ PR integration ممتاز. الشائع: CI في GitHub Actions، و CD إما Actions (OIDC) أو CodePipeline لو المنظمة AWS-centric أو محتاجة الـ deploy يتم من جوه الحساب ([58](58-ecs-github-actions-vs-codepipeline.md)).

</details>

<details><summary>ليه `stack50.auto.tfvars.json` بدل `terraform_remote_state`؟</summary>

`terraform_remote_state` بيربط الـ lifecycles: الـ plan بتاع 36 هيقرا state بتاع 50 (صلاحيات أوسع، ولو 50 اتعمله destroy الـ plan بيقع). الملف المتولّد decoupled وصريح وبيتعمل review، والـ defaults (أسماء مشتقة من project/env) بتخلّي الـ stack يشتغل من غيره. البدائل الأنضف في prod: SSM parameters كـ "contract" بين الـ stacks، أو data sources بالـ tags.

</details>

<details><summary>Cross-account pipeline — إيه اللي بيتغيّر؟</summary>

الـ artifact bucket لازم يتشفّر بـ **customer managed KMS key** (الـ `aws/s3` managed key مينفعش يتشارك cross-account) وkey policy تسمح للحساب التاني، وbucket policy، وroles في حساب الـ target الـ pipeline بيعملها assume لكل action (`role_arn` على الـ action). ده سبب إن المعمل (حساب واحد) استخدم `aws/s3` عن قصد.

</details>

## 13) Checklist

- [ ] بنيت pipeline من الـ Console (Source → Build → ECS) وشفت execution كامل
- [ ] ولّدت `stack50.auto.tfvars.json` وعملت stack 36 بـ Terraform
- [ ] جرّبت `require_approval` ووافقت من الـ CLI
- [ ] فهمت الـ 3 deploy modes ومتى كل واحد، والـ migration step
- [ ] جرّبت docs-only commit، migration فاشلة، و `QUEUED`
- [ ] عملت rollback-stage
- [ ] destroy بالترتيب: 36 قبل 50
