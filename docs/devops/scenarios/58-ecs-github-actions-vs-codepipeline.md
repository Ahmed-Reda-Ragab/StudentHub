# 58 — ECS deploy بـ GitHub Actions مقابل CodePipeline

> **الهدف في سطر:** تشغّل نفس الـ release على نفس الـ service بطريقتين وتقارن بجد: [`deploy-ecs.yml`](../../../.github/workflows/deploy-ecs.yml) (OIDC، render-taskdef `live`/`repo`، migration، deploy، smoke) مقابل [stack 36](../../../infra/terraform/stacks/36-codepipeline/) (Source بـ CodeConnections، CodeBuild buildspecs، deploy modes `ecs` / `codedeploy-ecs` / `codebuild`، approval اختياري، ومدخلات stack 50 عن طريق `stack50.auto.tfvars.json`) — من ناحية التكلفة والـ auditability وإمتى تختار أنهي واحد، وترتيب الـ destroy (36 قبل 50).
> **المستوى:** Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** نفس [51](51-ecs-fargate-terraform.md) + ~$0.05 لكل release على CodePipeline/CodeBuild (تقريبي)
> **بيعتمد على:** [30](30-ci-github-actions.md) · [35 — CodeBuild](35-aws-codebuild.md) · [36 — CodePipeline](36-aws-codepipeline.md) · [34 — Environments و approvals](34-environments-approvals-promotion.md) · [51](51-ecs-fargate-terraform.md)–[55](55-ecs-native-bluegreen-linear-canary.md) · **الملفات في الـ repo:** [`.github/workflows/deploy-ecs.yml`](../../../.github/workflows/deploy-ecs.yml) · [`stacks/36-codepipeline/main.tf`](../../../infra/terraform/stacks/36-codepipeline/main.tf) · [`stacks/36-codepipeline/variables.tf`](../../../infra/terraform/stacks/36-codepipeline/variables.tf) · [`modules/codepipeline/main.tf`](../../../infra/terraform/modules/codepipeline/main.tf) · [`modules/codebuild/`](../../../infra/terraform/modules/codebuild/) · [`deploy/codebuild/buildspec-build.yml`](../../../deploy/codebuild/buildspec-build.yml) · [`deploy/codebuild/buildspec-deploy-ecs.yml`](../../../deploy/codebuild/buildspec-deploy-ecs.yml) · [`deploy/ecs/render-taskdef.sh`](../../../deploy/ecs/render-taskdef.sh) · [`stacks/50-ecs-fargate/outputs.tf`](../../../infra/terraform/stacks/50-ecs-fargate/outputs.tf) · [`bootstrap/github-oidc.tf`](../../../infra/terraform/bootstrap/github-oidc.tf) · [`bootstrap/codeconnections.tf`](../../../infra/terraform/bootstrap/codeconnections.tf)

## 1) الفكرة (Concepts)

الاتنين بيعملوا نفس الـ 5 خطوات: **image موجودة (build once) → task definition بالـ image الجديدة → migrations مرة واحدة → deploy + wait → verify**. الفرق في: فين بيجري، بأنهي identity، مين بيوافق، وفين الـ audit trail.

| | GitHub Actions (`deploy-ecs.yml`) | CodePipeline (stack 36) |
|---|---|---|
| Trigger | `workflow_dispatch` يدوي (image_tag، strategy، taskdef_source، extra_env، run_migrations) | push على `branch` (V2 trigger، بيتجاهل `docs/**` و `**/*.md`) أو `start-pipeline-execution` |
| Identity في AWS | OIDC → `student-app-gha-deploy` (جلسة ساعة، `role-session-name: deploy-ecs-<run_id>`) | service roles: pipeline role + role لكل CodeBuild project (مفيش credentials بره AWS خالص) |
| الـ Image | `ci.yml` بناها وعمل push؛ الـ deploy **بيتأكد** إنها موجودة وبس | CodeBuild `buildspec-build.yml` يبني ويعمل push — **أو يتخطى** لو الـ tag موجود (immutable) |
| Task definition | `live` (أحدث revision في الـ family + image) أو `repo` (`task-definition.json`) | `ecs`: الـ action بيعمل copy لـ **revision الـ service الحالية** · `codedeploy-ecs`: `taskdef.json` (`repo` أو `live`) · `codebuild`: `live` |
| Migrations | `run-migrations.sh` بالـ revision المسجّلة | CodeBuild project `deploy` بـ `DEPLOY_STEP=migrate` (run_order 1) |
| Deploy | `amazon-ecs-deploy-task-definition` (ECS أو CodeDeploy) + wait 45 دقيقة | `ECS` action / `CodeDeployToECS` / CodeBuild (`update-service` + poll `rolloutState`) |
| Verify | smoke: `/ready` لازم `version == tag` + `/login` < 500 | مفيش smoke step (الـ ECS action بيستنى الـ stability؛ `codebuild` mode بيفشل لو `rolloutState = FAILED`) |
| Approval | GitHub environment `lab` (required reviewers) — نفس الـ environment اللي في الـ OIDC `sub` | Manual approval stage (`require_approval`) + SNS اختياري |
| Concurrency | `concurrency: deploy-ecs-lab`، `cancel-in-progress: false` | `execution_mode = QUEUED` |
| Drills | `extra_env` (KEY=value) | مفيش — env من Terraform بس |
| Audit | سجل الـ run + environment deployments في GitHub + CloudTrail (اسم الـ session فيه الـ run id) | CodePipeline execution history + CodeBuild logs (CloudWatch) + CloudTrail — كله جوه الحساب |

## 2) المعمارية (Architecture)

```text
 GitHub Actions                                          CodePipeline V2  (student-app-lab-pipeline, QUEUED)
 ─────────────                                           ────────────────────────────────────────────────
 ci.yml (push master) ── build → scan → push :sha7       Source  CodeStarSourceConnection (CodeConnections)
                                                                 Ahmed-Reda-Ragab/StudentHub @ master
 deploy-ecs.yml (dispatch, environment: lab)                      │ source_output
  OIDC → student-app-gha-deploy                          Build   CodeBuild student-app-lab-pipeline-image
  ├ ECR describe-images (tag موجود؟)                              buildspec-build.yml: tag = CODEBUILD_RESOLVED_SOURCE_VERSION[:7]
  ├ controller/strategy check                                     skip build لو موجود · push · artifacts:
  ├ render-taskdef.sh live|repo                                   imagedefinitions.json imageDetail.json taskdef.json appspec.yaml
  ├ amazon-ecs-render-task-definition (+extra_env)                │ build_output (#{BuildVariables.IMAGE_URI})
  ├ register                                              [Approve] Manual "Promote"           (require_approval)
  ├ run-migrations.sh                                     Deploy  1: Migrate  CodeBuild ...-pipeline-deploy (DEPLOY_STEP=migrate)
  ├ deploy (ECS | CodeDeploy appspec) + wait                      2: ecs            → ECS action (imagedefinitions.json)
  └ smoke /ready version == tag                                      codedeploy-ecs → CodeDeployToECS (taskdef.json + appspec.yaml)
                                                                  1: codebuild      → MigrateAndDeploy (DEPLOY_STEP=all)
                   ╲                                         ╱
                    ╲──────► ECS service student-app-lab-app ◄╱   (stack 50)
```

## 3) المتطلبات (Prerequisites)

- [ ] **bootstrap:** `student-app-gha-deploy` (trust: `main`/`master` و environments `lab`/`production`)، ECR `student-app`، و CodeConnections `student-app-github` في حالة **AVAILABLE**:

```bash
ARN=$(terraform -chdir=infra/terraform/bootstrap output -raw codeconnections_arn)
aws codeconnections get-connection --connection-arn "$ARN" --query Connection.ConnectionStatus   # AVAILABLE
```

  لو `PENDING`: **Developer Tools → Settings → Connections → `student-app-github` → Update pending connection** → ثبّت/اسمح لـ "AWS Connector for GitHub" على الـ repo ([`codeconnections.tf`](../../../infra/terraform/bootstrap/codeconnections.tf)).
- [ ] stack 50 شغال ([51](51-ecs-fargate-terraform.md)) والـ GitHub variables متظبطة (`AWS_DEPLOY_ROLE_ARN`، `ECS_CLUSTER`، `ECS_SERVICE`، `ECS_APP_URL`).
- [ ] GitHub environment `lab` (Settings → Environments) — حط required reviewer لو عايز approval ([34](34-environments-approvals-promotion.md)).
- [ ] (اختياري) عايز تعمل apply لـ stack 36 من GitHub (Actions → Terraform)؟ الـ workflow بيمرر `TF_VAR_codeconnections_arn` من repo variable **`CODECONNECTIONS_ARN`** (موجودة في `github_repository_variables` بتاع الـ bootstrap): `gh variable set CODECONNECTIONS_ARN --body "$ARN"`. (ملف `stack50.auto.tfvars.json` مش في الـ repo، فالـ CI run هيستخدم أسماء stack 50 الافتراضية.)

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 GitHub

**Actions → Deploy ECS → Run workflow** → `image_tag` (فاضي = SHA الـ ref)، `strategy`، `taskdef_source`، `extra_env`، `run_migrations` (سيبه ✅). لو الـ environment عليه reviewer: الـ job يستنى **Review deployments → Approve**. بعد الـ run: الـ **job summary** فيه الـ image، الـ strategy، الـ revision القديمة والجديدة، و CodeDeploy ID، وأمر الـ rollback. و **Environments → lab** فيه تاريخ الـ deployments.

### 4.2 CodePipeline

1. **CodePipeline → Pipelines → `student-app-lab-pipeline`**: الـ stages، وكل execution بالـ commit (Source revision).
2. **Release change** = execution جديد من آخر commit.
3. **Approve → Review** → Approve/Reject بتعليق (الـ CustomData: `Deploy #{BuildVariables.IMAGE_URI} to student-app-lab-app?`).
4. اضغط على أي action → **Details** → CodeBuild build logs (فيها output الـ migrations: `── /ecs/student-app-lab/app  app/app/<task-id>`).
5. **Execution history** → مين بدأ، أنهي commit، النتيجة — ده الـ audit trail.
6. (V2) لو stage فشل: **Retry** (نفس الـ artifacts) — وفيه كمان **Start rollback** على الـ stage لـ execution ناجح قبل كده (لو ظاهر في حسابك).

## 5) الطريقة التانية: Infrastructure as Code

### 5.1 `deploy-ecs.yml` خطوة بخطوة

| Step | بيعمل إيه | ليه |
|---|---|---|
| Resolve image tag | `inputs.image_tag` أو `GITHUB_SHA::7`؛ يرفض `latest` و أي حاجة مش `^[A-Za-z0-9._-]{1,128}$` | immutable tags ([CONVENTIONS §2](../CONVENTIONS.md)) |
| OIDC | `configure-aws-credentials@v6` → `vars.AWS_DEPLOY_ROLE_ARN` | الـ job فيه `environment: lab` → الـ `sub` = `repo:...:environment:lab` (مش الـ branch!) |
| Image exists in ECR | `describe-images` | build once, deploy many — مش بيبني |
| Service matches the strategy | `deploymentController.type` + `deploymentConfiguration.strategy` مقابل الـ input | يمنع `codedeploy` على service ECS أو `native` على ROLLING |
| Task definition | `live`: `render-taskdef.sh live <family>` (بيشيل أي `SRE_FAULT_*` من الـ copy) · `repo`: `render-taskdef.sh repo task-definition.json` (+ `AWS_ACCOUNT_ID` من STS) | Terraform يملك الـ env، الـ CI يملك الـ image، والـ faults عمرها ما بتتورّث |
| Extra environment | `extra_env` → يتأكد `^[A-Z_][A-Z0-9_]*=[^[:space:]]*$` → multiline output بـ delimiter عشوائي | الـ drills ([53](53-ecs-rolling-circuit-breaker.md)) لـ deploy واحد بس، من غير تعديل Terraform |
| Render | `amazon-ecs-render-task-definition@v1` (container `app`، image، env) | |
| Register | `amazon-ecs-deploy-task-definition@v2` من غير service | الـ migration لازم تجري بالـ revision الجديدة **قبل** ما أي task يخدمها (الـ deploy step بيسجّل نسخة تانية مطابقة لأن الـ action بياخد ملف مش ARN) |
| Migrations | `run-migrations.sh --task-definition <arn>` — `if: inputs.run_migrations` (default `true`) | `false` للـ boot-fail drill بس ([53 §8.1](53-ecs-rolling-circuit-breaker.md)): image بايظة مش هتعرف تعمل migrate |
| Deploy | ECS: `wait-for-service-stability`، `wait-for-minutes: 45` · CodeDeploy: `codedeploy-appspec` + app/DG (default `student-app-lab-ecs`) | |
| Smoke | `/ready` لحد 20 محاولة × 6s لازم `version == tag` + `/login` < 500 | بيكشف الـ silent rollback |
| Job summary | دايماً (`if: always()`) | rollback جاهز |

### 5.2 Stack 36 ([`main.tf`](../../../infra/terraform/stacks/36-codepipeline/main.tf))

**المدخلات من stack 50 من غير copy/paste:**

```bash
cd infra/terraform/stacks/36-codepipeline
terraform -chdir=../50-ecs-fargate output -json pipeline_inputs > stack50.auto.tfvars.json
cat stack50.auto.tfvars.json
```

المفاتيح = أسماء variables الـ stack: `ecs_cluster_name`، `ecs_service_name`، `task_family`، `task_execution_role_arn`، `task_role_arn`، `app_log_group_arn`، `codedeploy_app_name`، `codedeploy_deployment_group_name` (`null` لو stack 50 مش CODE_DEPLOY). من غير الملف، الـ stack بيفترض أسماء stack 50 الافتراضية (`coalesce` في الـ locals). **اعمله regenerate بعد ما تحوّل stack 50 لـ CODE_DEPLOY.**

| Variable | Default | المعنى |
|---|---|---|
| `codeconnections_arn` | **مطلوب** | `terraform -chdir=../../bootstrap output -raw codeconnections_arn` |
| `branch` | `master` | الـ trigger + الـ source |
| `deploy_mode` | `ecs` | `ecs` / `codedeploy-ecs` / `codebuild` |
| `run_migrations` | `true` | Migrate step قبل الـ deploy action (`ecs` و `codedeploy-ecs`) |
| `require_approval` | `false` | stage `Approve` بـ action `Promote` |
| `approval_sns_topic_arn` | `null` | إشعار الموافقة |
| `taskdef_source` | `repo` | لـ `codedeploy-ecs`: `taskdef.json` من الـ repo أو copy للـ live (`live` بيدّي الـ image project `ecs:DescribeTaskDefinition`) |
| `build_image` | `aws/codebuild/standard:8.0` | |

**الـ deploy modes:**

| `deploy_mode` | الـ Deploy stage | الـ service لازم يكون | ملاحظة |
|---|---|---|---|
| `ecs` | `Migrate` (CodeBuild، `DEPLOY_STEP=migrate`) → `ECS` action (`imagedefinitions.json`، `DeploymentTimeout` 30 دقيقة) | `ECS` (rolling أو native B/G/linear/canary — الـ strategy بتاعة الـ service هي اللي بتشتغل) | الـ action بيعمل copy لـ **revision الـ service الحالية** → تعديلات Terraform على الـ env **مش هتوصل** غير بعد `codebuild` أو GitHub deploy. والـ Migrate step بيسجّل revision لوحده من **أحدث** revision في الـ family — يعني ممكن الـ migration تجري بـ env مختلف عن اللي اتعمله deploy |
| `codedeploy-ecs` | `Migrate` → `CodeDeployBlueGreen` (`CodeDeployToECS`: `taskdef.json` + `appspec.yaml`، `Image1ContainerName = IMAGE1_NAME` بيتبدّل من `imageDetail.json`) | `CODE_DEPLOY` + الـ codedeploy module ([54](54-ecs-codedeploy-bluegreen-canary.md)) | مع `taskdef_source=repo`، [`taskdef.json`](../../../deploy/ecs/taskdef.json) لازم يفضل متزامن يدوياً مع env/SSM keys بتوع stack 50 |
| `codebuild` | `MigrateAndDeploy` (CodeBuild، `DEPLOY_STEP=all`) | `ECS` | نفس منطق GitHub: `live` + register + migrate + `update-service` + poll `rolloutState` (COMPLETED / FAILED → exit 1) |

**الأمان في الـ stack:**

- الـ deploy project role ([`main.tf`](../../../infra/terraform/stacks/36-codepipeline/main.tf) `data.aws_iam_policy_document.deploy`): `DescribeServices/UpdateService` على **service واحد**، `RunTask` على الـ family دي **في الـ cluster ده بس** (`ecs:cluster` condition)، `iam:PassRole` على الـ execution/task roles **لـ `ecs-tasks.amazonaws.com` بس**، `ecs:TagResource` عند الإنشاء بس، `logs:GetLogEvents` على log group الـ app.
- الـ artifact bucket: SSE-KMS (`aws/s3`، bucket key)، public access block، `BucketOwnerEnforced`، deny لأي request مش TLS، expiry 14 يوم، `force_destroy = true` (ephemeral).
- الـ pipeline role: `codeconnections:UseConnection` على connection واحد، CodeBuild على الـ projects بتاعته بس، وصلاحيات ECS/CodeDeploy حسب الـ `deploy_mode`.

### 5.3 الـ buildspecs

| Buildspec | أهم سطور |
|---|---|
| [`buildspec-build.yml`](../../../deploy/codebuild/buildspec-build.yml) | `AWS_ACCOUNT_ID` من `CODEBUILD_BUILD_ARN` (لو مش متمرر)؛ `IMAGE_TAG = CODEBUILD_RESOLVED_SOURCE_VERSION[:7]`؛ `describe-images` → skip لو موجود؛ `post_build` بيرفض يطلّع artifacts لو الـ build فشل؛ `exported-variables: IMAGE_URI, IMAGE_TAG` |
| [`buildspec-deploy-ecs.yml`](../../../deploy/codebuild/buildspec-deploy-ecs.yml) | `IMAGE_URI` من `$CODEBUILD_SRC_DIR_build_output/imageDetail.json`؛ يرفض `:latest`؛ `render-taskdef.sh live` → register → `run-migrations.sh`؛ `DEPLOY_STEP != all` → يخرج بعد الـ migration؛ غير كده `update-service` و poll كل 15s لحد `WAIT_MINUTES` (30) |

## 6) الـ Deploy

### 6.1 GitHub Actions

```bash
gh workflow run deploy-ecs.yml --ref master -f strategy=rolling -f taskdef_source=live
gh run watch
gh run view --log | grep -E "migrations|rollout|ready:|::error" | tail -20
```

### 6.2 CodePipeline

```bash
cd infra/terraform/stacks/36-codepipeline
cp terraform.tfvars.example terraform.tfvars        # codeconnections_arn، deploy_mode، require_approval
terraform -chdir=../50-ecs-fargate output -json pipeline_inputs > stack50.auto.tfvars.json
terraform init -backend-config=../../backend.hcl
terraform plan -out=tfplan && terraform apply tfplan   # V2 pipeline بيبدأ execution أول ما يتعمل
terraform output -raw pipeline_console_url
eval "$(terraform output -raw start_command)"          # execution يدوي من غير push
```

الموافقة من الـ CLI (لو `require_approval = true`):

```bash
P=student-app-lab-pipeline
T=$(aws codepipeline get-pipeline-state --name $P \
  --query "stageStates[?stageName=='Approve'].actionStates[0].latestExecution.token" --output text)
aws codepipeline put-approval-result --pipeline-name $P --stage-name Approve --action-name Promote \
  --result summary="smoke ok on staging",status=Approved --token "$T"
```

### 6.3 قارن الاتنين على نفس الـ commit

```bash
URL=$(terraform -chdir=infra/terraform/stacks/50-ecs-fargate output -raw app_url)
bash deploy/scripts/probe.sh "$URL/ready" 600 0.2      # شغّاله وانت بتعمل deploy بكل طريقة: failed لازم 0
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app \
  --query 'services[0].deployments[].[status,rolloutState,taskDefinition,createdAt]' --output table
aws ecs list-task-definitions --family-prefix student-app-lab-app --sort DESC --max-items 5
```

سجّل لكل طريقة: الوقت من الـ trigger لحد `COMPLETED`، عدد الـ revisions اللي اتسجلت، فين لقيت logs الـ migration، ومين/إمتى في الـ audit.

## 7) التحقق (Verify)

```bash
aws codepipeline list-pipeline-executions --pipeline-name student-app-lab-pipeline --max-items 3 \
  --query 'pipelineExecutionSummaries[].[status,sourceRevisions[0].revisionId,trigger.triggerType,startTime]' --output table
aws codebuild list-builds-for-project --project-name student-app-lab-pipeline-image --max-items 3
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=UpdateService --max-results 5 \
  --query 'Events[].[EventTime,Username]' --output table      # deploy-ecs-<run_id> مقابل CodeBuild/CodePipeline role sessions
gh run list --workflow=deploy-ecs.yml --limit 5
curl -s "$URL/ready" | jq '{version,color}'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر/السيناريو | المتوقع |
|---|---|---|
| Race على نفس الـ SHA | push على `master` و stack 36 شغال: `ci.yml` و الـ pipeline الاتنين بيبنوا نفس الـ tag | الاتنين بيعملوا `describe-images` قبل الـ push، بس لو الاتنين بيبنوا في نفس الوقت، التاني هيفشل في الـ push بـ `ImageTagAlreadyExistsException` (IMMUTABLE). الحل: الـ pipeline يعتمد على الـ CI image (يستنى/يتخطى)، أو trigger واحد بس |
| Terraform env مش واصل | `app_environment = { DEPLOY_COLOR = "green" }` + apply على 50 ← push (deploy_mode = `ecs`) | الـ ECS action عمل copy لـ revision الـ service القديمة → `/ready` لسه `"color":"stable"`. `codebuild` mode أو GitHub `live` → `"green"` (متستخدمش `SRE_FAULT_*` هنا: الـ `live` render بيشيلها) |
| Connection مش AVAILABLE | connection `PENDING` | Source يفشل: `Unable to use Connection ... The provided connection is not in AVAILABLE state` |
| Mode غلط | `deploy_mode = "codedeploy-ecs"` والـ service `ECS` | الـ `CodeDeployToECS` يفشل (مفيش deployment group/الـ service مش CODE_DEPLOY)؛ ونفس الفكرة في GitHub بتتمسك بدري في step "Service matches the strategy" |
| Docs-only commit | push بيعدّل `docs/` بس | الـ pipeline مبيبدأش (`trigger_file_path_excludes`) — ونفس الحاجة `ci.yml` (`paths-ignore`) |
| Migration فاشلة | migration بايظة في commit | GitHub: يقف عند Migrations · Pipeline: `Migrate` action يفشل والـ `ECS` action (run_order 2) مبيجريش |
| Destroy بالترتيب الغلط | `terraform destroy` على 50 و 36 لسه موجود | الـ pipeline الجاي يفشل (service/roles مش موجودين)، والـ plan بتاع 36 بقى بيشاور على حاجات ممسوحة. **36 الأول دايماً** |

## 9) الرجوع (Rollback)

| | GitHub Actions | CodePipeline |
|---|---|---|
| أسرع rollback | re-run بـ `image_tag=<OLD_SHA7>`، أو الأمر اللي في الـ job summary (`update-service --task-definition <previous>`) | `update-service` يدوي، أو (V2) stage rollback لـ execution ناجح قبل كده، أو `git revert` + push |
| أثناء الـ deploy | circuit breaker / alarms / CodeDeploy auto-rollback (نفسهم — ملك الـ service مش الـ pipeline) | نفسه |

> الـ rollback الحقيقي ملك **الـ service/الـ deployer** (circuit breaker، alarms، CodeDeploy)، مش أداة الـ CI/CD. الأداة بتحدد بس مين بيبدأ الـ deploy ومين بيوافق.

## 10) المسح (Teardown) ⚠️

```bash
# 1) stack 36 الأول (بيشاور على service و roles بتوع stack 50)
cd infra/terraform/stacks/36-codepipeline
terraform destroy                      # الـ artifact bucket force_destroy = true
rm -f stack50.auto.tfvars.json
# 2) بعدين stack 50
cd ../50-ecs-fargate && terraform destroy
```

الـ CodeConnections والـ OIDC roles في الـ bootstrap مجانيين — سيبهم. امسح أي GitHub environment protection عملته للتجربة لو مش محتاجه.

## 11) التكلفة (Cost)

| Item | GitHub Actions | CodePipeline/CodeBuild (us-east-1، تقريبي — راجع صفحة الأسعار) |
|---|---|---|
| Orchestration | مجاني للـ public repo؛ private: دقائق مجانية/شهر ثم بالدقيقة | V2: ~$0.002 لكل action-execution-minute (أول 100 دقيقة/شهر مجاناً)، مفيش تكلفة idle |
| Build | ضمن الـ CI (`ci.yml`) | CodeBuild `BUILD_GENERAL1_SMALL` ~$0.005/دقيقة: image ~6 دقايق + migrate ~2 ≈ ~$0.04–0.05 لكل release |
| Storage | GHA cache مجاني (ضمن الـ quota) | S3 artifacts: سنتات (expiry 14 يوم) |
| Logs | GitHub run logs | CloudWatch Logs للـ CodeBuild (سنتات) |
| الـ deploy نفسه | نفس تكلفة الـ service | نفسه |

## 12) أسئلة Interview

<details><summary>GitHub Actions ولا CodePipeline لـ ECS؟ إزاي تقرر؟</summary>

GitHub Actions: الكود والـ PRs والـ approvals في مكان واحد، ecosystem ضخم، سهل للمطورين، و OIDC بيشيل مشكلة الـ keys. CodePipeline: كل حاجة جوه الحساب (compliance، data residency، مفيش identity خارجية بصلاحيات deploy)، تكامل native مع CodeDeploy/ECS، CloudTrail + execution history كـ audit موحّد، وCodeBuild ممكن يجري جوه الـ VPC. القرار غالباً تنظيمي (مين يملك الـ pipeline، متطلبات الـ audit) أكتر منه تقني. ومينفعش الاتنين يعملوا trigger على نفس الـ branch من غير ما تحدد مين مالك الـ build.

</details>

<details><summary>ليه الـ `ECS` deploy action في CodePipeline مش بيشوف تعديلات Terraform على الـ env؟</summary>

لأنه بياخد الـ task definition اللي الـ service شغالها دلوقتي ويغيّر الـ image بس (عن طريق `imagedefinitions.json`). Terraform سجّل revision أحدث في الـ family بس الـ service مش عليها (`ignore_changes`). الحلول: deployer بيعمل copy لأحدث revision (`render-taskdef.sh live` — الـ `codebuild` mode أو GitHub)، أو task definition كاملة في الـ repo (`CodeDeployToECS` + `taskdef.json`)، أو Terraform يعمل `update-service` (ويرجع يملك الـ image — مش عايزين ده).

</details>

<details><summary>إزاي تثبت لـ auditor مين عمل deploy لإيه وإمتى في الطريقتين؟</summary>

GitHub: الـ run (actor، commit، inputs)، environment deployment history (مين وافق)، و CloudTrail فيه `AssumeRoleWithWebIdentity` بـ `sub` الـ repo/environment و session name `deploy-ecs-<run_id>` بيربط الـ API calls بالـ run. CodePipeline: execution history (trigger، source revision)، approval result (مين وافق بـ IAM identity)، CodeBuild logs، و CloudTrail بـ roles الـ pipeline. نقطة مهمة: في GitHub الـ approver identity في GitHub مش IAM — لو الـ compliance عايز IAM-based approvals، CodePipeline أوضح.

</details>

<details><summary>الـ migration بتجري فين في كل pipeline، وليه run_order مهم؟</summary>

GitHub: step قبل الـ deploy بنفس الـ revision المسجّلة. CodePipeline: action `Migrate` بـ `run_order = 1` جوه stage الـ Deploy، والـ deploy action بـ `run_order = 2` — فلو الـ migration فشلت، الـ deploy مبيبدأش. في `ecs` mode فيه تفصيلة: الـ Migrate بيسجّل revision من أحدث الـ family، والـ ECS action بيعمل copy لـ revision الـ service — ممكن يختلفوا في الـ env. الصح إن الـ migration والـ deploy يستخدموا **نفس** الـ revision ARN (زي GitHub و `codebuild` mode).

</details>

<details><summary>إيه مخاطر الـ `extra_env` في `deploy-ecs.yml` مع `taskdef_source=live`؟</summary>

الـ extra env بيتسجّل في الـ revision، والـ revision دي بتبقى أحدث revision في الـ family، فالـ deploy الجاي بـ `live` بيعمل copy ليها. ده كان bug حقيقي في المعمل: fault الـ drill كان بيتورّث لكل deploy بعده. الحل في [`render-taskdef.sh`](../../../deploy/ecs/render-taskdef.sh): الـ `live` mode بيشيل كل `SRE_FAULT_*` من الـ copy (`KEEP_FAULT_ENV=true` يحتفظ بيها). بس خلي بالك: أي `extra_env` **تاني** (مثلاً `DEPLOY_COLOR=green`) لسه بيتورّث. الدرس العام: أي "source of truth" بيتبني من الـ state الحالية (مش من الـ code) بيورّث أي تعديل مؤقت — وده trade-off الـ `live` مقابل `repo`، والحل إما allowlist/denylist صريحة زي دي أو task definition كاملة في الـ repo.

</details>

<details><summary>ليه `cancel-in-progress: false` و `QUEUED`؟</summary>

deployment اتقطع في النص = service في حالة نص-نص (traffic بيتحوّل، migration جريت، CodeDeploy شغال). الأحسن الـ deploys تتصف وتتنفذ بالترتيب. `SUPERSEDED` (CodePipeline) أو `cancel-in-progress: true` مناسبين للـ CI/builds، مش للـ deploys اللي بتغيّر production.

</details>

## 13) Checklist

- [ ] عملت deploy بـ `deploy-ecs.yml` وقريت الـ job summary
- [ ] الـ CodeConnections AVAILABLE وولّدت `stack50.auto.tfvars.json`
- [ ] عملت apply لـ stack 36 بـ `deploy_mode = ecs` وبعدين `codebuild` (و `codedeploy-ecs` مع [54](54-ecs-codedeploy-bluegreen-canary.md))
- [ ] جرّبت الـ manual approval من الـ console والـ CLI
- [ ] قارنت الوقت والـ revisions والـ logs والـ audit بين الطريقتين
- [ ] جرّبت سيناريو "Terraform env مش واصل" مع الـ ECS action
- [ ] عملت destroy لـ 36 قبل 50
