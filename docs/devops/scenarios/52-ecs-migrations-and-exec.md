# 52 — Migrations كـ one-off task + ECS Exec

> **الهدف في سطر:** تشغّل `php artisan migrate --force` **مرة واحدة لكل release** كـ one-off ECS task بـ [`run-migrations.sh`](../../../deploy/ecs/run-migrations.sh) وتفهم ليه "STOPPED" مش معناها "نجح"، وتدخل جوه task شغال من غير SSH بـ **ECS Exec** ([`ecs-exec.sh`](../../../deploy/ecs/ecs-exec.sh)) وتعرف ليه `initProcessEnabled = false` مع S6 كـ PID 1، ومعاك checklist للـ debugging.
> **المستوى:** Intermediate · **الوقت:** ~2 ساعة · **التكلفة التقريبية:** نفس [51](51-ecs-fargate-terraform.md) + سنتات لكل one-off task
> **بيعتمد على:** [51 — ECS بـ Terraform](51-ecs-fargate-terraform.md) (أو [50](50-ecs-fargate-console.md)) · [95 — Migrations من غير downtime](95-zero-downtime-db-migrations.md) · **الملفات في الـ repo:** [`deploy/ecs/run-migrations.sh`](../../../deploy/ecs/run-migrations.sh) · [`deploy/ecs/ecs-exec.sh`](../../../deploy/ecs/ecs-exec.sh) · [`deploy/ecs/README.md`](../../../deploy/ecs/README.md) · [`modules/ecs-fargate/iam.tf`](../../../infra/terraform/modules/ecs-fargate/iam.tf) · [`modules/ecs-fargate/variables.tf`](../../../infra/terraform/modules/ecs-fargate/variables.tf) · [`docker/Dockerfile`](../../../docker/Dockerfile) · [`stacks/50-ecs-fargate/outputs.tf`](../../../infra/terraform/stacks/50-ecs-fargate/outputs.tf)

## 1) الفكرة (Concepts)

### ليه مش في الـ container start؟

الـ image فيها `AUTORUN_ENABLED=true` (بيعمل `php artisan optimize` عند كل start — config/route/view cache بالـ env الحقيقية) و **`AUTORUN_LARAVEL_MIGRATION=false`** ([`Dockerfile`](../../../docker/Dockerfile)، [CONVENTIONS §2](../CONVENTIONS.md)). ليه نقفل الـ migration عند الـ boot؟

| المشكلة لو migrate مع كل replica | التفصيل |
|---|---|
| Race | deployment بـ max 200% = لحد 4 tasks بيعملوا migrate في نفس اللحظة على نفس الـ schema |
| Crash loop | migration فاشلة = كل task جديد يقع → الـ circuit breaker يرجّع، وإنت مش عارف الـ schema في أنهي حالة |
| ترتيب غلط | الـ task بيبدأ ياخد traffic (بعد `/ready`) وممكن replica تانية لسه بتعمل `ALTER` |
| Spot | task على `FARGATE_SPOT` ممكن يتسحب في نص الـ migration |
| مفيش gate | مفيش exit code واحد يقرر "نكمّل الـ deploy ولا لأ" |

الحل: **one-off task** بنفس الـ revision الجديدة (نفس الـ image + env + secrets)، command override `php artisan migrate --force`، على **on-demand `FARGATE`**، و**قبل** ما الـ service يتحدّث. لو فشل → الـ pipeline يقف والـ release القديم لسه شغال 100%.

> ⚠️ الـ migration بتجري والكود **القديم** لسه بيخدم → لازم expand/contract ([95](95-zero-downtime-db-migrations.md)).
> ⚠️ `migrate --isolated` محتاج cache lock؛ مع `CACHE_STORE=database` الجدول `cache_locks` مش موجود في أول migration → متستخدمهوش على DB فاضية.

### ECS Exec

| المصطلح | المعنى |
|---|---|
| ECS Exec | `aws ecs execute-command` → shell أو أمر جوه container شغال، عن طريق **SSM Session Manager**: مفيش SSH، مفيش بورت مفتوح، مفيش keys |
| SSM agent | Fargate بيحقنه جوه الـ task لو `enableExecuteCommand=true` **وقت start الـ task** |
| `ssmmessages:*` | الـ agent بيفتح قنوات control/data للـ SSM بالـ **task role** |
| session-manager-plugin | binary على جهازك الـ AWS CLI بيستخدمه للـ interactive session |
| `initProcessEnabled` | ECS يحقن `tini` كـ PID 1 يعمل reap للـ zombies (بيتنصح بيه مع Exec عادةً) |

**ليه `initProcessEnabled = false` هنا؟** الـ image مبنية على `serversideup/php:*-fpm-nginx` اللي بتشغّل **S6 overlay** (بيدير nginx + php-fpm). S6 لازم يبقى **PID 1** وإلا بيقع بـ `s6-overlay-suexec: fatal: can only run as pid 1`. وS6 أصلاً بيعمل reap للـ zombie processes — ومنها processes الـ SSM agent اللي Exec بيعملها. فـ `tini` هنا مش بس مالوش لازمة، ده بيكسر الـ container ([`variables.tf`](../../../infra/terraform/modules/ecs-fargate/variables.tf)، [`README`](../../../infra/terraform/modules/ecs-fargate/README.md)).

## 2) المعمارية (Architecture)

```text
 Migration (once per release)                        ECS Exec (debug)
 ───────────────────────────                         ─────────────────
 register revision N+1 (new image)                    laptop: aws ecs execute-command
        │                                                    │ (session-manager-plugin)
        ▼                                                    ▼
 run-migrations.sh                                     ECS API ──► SSM Session Manager
   ├ resolve task def / network from the service              ▲
   │   (CODE_DEPLOY: PRIMARY task set)                         │ ssmmessages (task role)
   ├ aws ecs run-task  capacityProvider=FARGATE                │
   │   overrides: app → ["php","artisan","migrate","--force"]  ┌┴──────────────────────────┐
   ├ poll describe-tasks every 10s (TIMEOUT 900s)              │ task  (S6 = PID 1)         │
   ├ containers[app].exitCode == 0 ?                           │   ├ nginx / php-fpm        │
   ├ print last 50 log lines (app/app/<task-id>)               │   └ SSM agent → /bin/sh    │
   └ exit 0 → deploy continues | exit 1 → pipeline stops       └───────────────────────────┘
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 50 شغال ([51](51-ecs-fargate-terraform.md)) أو الـ console setup ([50](50-ecs-fargate-console.md)) بـ **Turn on ECS Exec**.
- [ ] AWS CLI **v2** + `jq`.
- [ ] **Session Manager plugin** على الجهاز:
  - Windows: الـ installer من صفحة AWS "Install the Session Manager plugin for the AWS CLI" (`SessionManagerPluginSetup.exe`)، وبعدها افتح terminal جديد.
  - WSL/Ubuntu:

```bash
curl -fsSLo /tmp/smp.deb "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb"
sudo dpkg -i /tmp/smp.deb && session-manager-plugin --version
```

- [ ] صلاحيات الـ IAM user/role بتاعك: `ecs:ExecuteCommand` و `ecs:DescribeTasks` و `ecs:ListTasks` (الـ admin profile فيها).

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 Migration من الـ console

نفس [50 §4.10](50-ecs-fargate-console.md): **Cluster → Tasks → Run new task** → Launch type **FARGATE** · Task definition = الـ revision الجديدة · Networking = نفس subnets/SG الـ service + Public IP (لو مفيش NAT) · **Container overrides → app → Command override** `php,artisan,migrate,--force` → **Create**.

التحقق: افتح الـ task لما يبقى **Stopped**:

- **Stopped reason:** `Essential container in task exited` (طبيعي — الأمر خلص).
- **Containers → app → Exit code:** لازم **0**. أي رقم تاني = فشل.
- تاب **Logs:** الـ migrations اللي اتعملت (`... DONE`) أو الـ exception.

### 4.2 تفعيل ECS Exec على service موجود

**Service → Update service → Troubleshooting configuration → ✅ Turn on ECS Exec** + ✅ **Force new deployment** → Update. (Exec بيتقرر وقت start الـ task؛ الـ tasks القديمة مش هتتفعل.)

### 4.3 Exec من الـ console

افتح **Task → Containers → `app`** → زرار **Connect** (لو ظاهر في حسابك) بيفتح session في **CloudShell** ببيئة جاهزة فيها الـ plugin. لو مش ظاهر استخدم الـ CLI (§6.2).

## 5) الطريقة التانية: Infrastructure as Code

### 5.1 اللي في الـ Terraform

| المكان | الإعداد |
|---|---|
| `aws_ecs_service.app` | `enable_execute_command = var.enable_execute_command` (default `true`) |
| `aws_iam_role_policy.task_exec` | الـ task role: `ssmmessages:CreateControlChannel/CreateDataChannel/OpenControlChannel/OpenDataChannel` على `*` (مفيش resource-level permissions للـ ssmmessages) + `logs:CreateLogStream/DescribeLogStreams/PutLogEvents` على log group الـ app + `logs:DescribeLogGroups` (للـ session logs) |
| `aws_ecs_cluster.this` | `execute_command_configuration { logging = "DEFAULT" }` → output كل session بيتكتب في الـ `awslogs` group بتاع الـ container (`/ecs/student-app-lab/app`) بالـ task role |
| container definition | `linuxParameters.initProcessEnabled = var.init_process_enabled` (default `false`) |
| outputs | `migration_command` (خام)، `migration_script_command`، `ecs_exec_command`، `run_task_network_configuration` |

> 💡 **الـ audit على مستويين:** CloudTrail بيسجّل كل `ExecuteCommand` (مين، على أنهي task، إمتى)، و **output الـ session نفسه** بيتكتب في `/ecs/student-app-lab/app` (logging `DEFAULT`). الـ SSM agent جوه الـ task هو اللي بيكتب الـ logs دي بالـ **task role** — عشان كده الـ task role فيه صلاحيات `logs:*` على log group الـ app بس، مش الـ execution role. لو شيلتها، الـ session بيشتغل عادي بس الـ output مش بيتسجّل (silent gap في الـ audit).

### 5.2 `run-migrations.sh` خطوة بخطوة

| # | الخطوة | التفاصيل |
|---|---|---|
| 1 | args / env | `--cluster` (`ECS_CLUSTER`)، `--service` (`ECS_SERVICE`)، `--task-definition` (`TASK_DEFINITION`)، `--network-configuration` (`NETWORK_CONFIGURATION`)، `--capacity-provider` (`CAPACITY_PROVIDER`، default **`FARGATE`**)، `--timeout` (`TIMEOUT_SECONDS`، default **900**) |
| 2 | resolve | لو مفيش task def → **revision الـ service الحالية** (re-run migrations للـ release الشغال). لو مفيش network → **subnets/SGs/public-IP بتوع الـ service**. خدمات `CODE_DEPLOY` بتشيل الحاجتين على الـ **PRIMARY task set** مش على الـ service، والسكريبت بيتعامل مع ده |
| 3 | `run-task` | `--capacity-provider-strategy capacityProvider=FARGATE,weight=1`، `--overrides` على container `app` بـ `["php","artisan","migrate","--force"]`، `--started-by migrations`، managed tags + propagate من الـ task definition. لو `failures[]` مش فاضية → exit 1 |
| 4 | wait | loop خاص كل 10s لحد `STOPPED` (الـ CLI waiter بيستسلم بعد ~10 دقايق). لو الـ timeout خلص: exit 1 **ومبيقتلش الـ task** ("a killed migration is worse") |
| 5 | exit code | `containers[name=="app"].exitCode` + `stoppedReason` |
| 6 | logs | من الـ task definition بيجيب `awslogs-group` و `awslogs-stream-prefix` ويطبع آخر 50 سطر من `app/app/<task-id>` |
| 7 | النتيجة | exit code ≠ 0 → `✖ migrations failed: exit code N` و exit 1 · غير كده `✔ migrations done` |

Exit codes بتاعة السكريبت نفسه: `64` (argument غلط)، `66` (مش لاقي task def / network)، `69` (`aws`/`jq` مش موجودين)، `1` (فشل الـ task أو الـ migration).

> 💡 **"STOPPED" مقابل "نجح":** `describe-tasks` فيه `stopCode` (مثلاً `EssentialContainerExited`) وده معناه إن الـ container خلص — مش إنه نجح. الحقيقة في `containers[].exitCode`. وكمان لو الـ task فشل يقوم أصلاً (secret غلط، image مش موجودة) الـ `exitCode` بيبقى فاضي → السكريبت بيعتبره `none` ≠ `0` → فشل. ده صح.

### 5.3 `ecs-exec.sh`

| الخطوة | التفاصيل |
|---|---|
| defaults | `ECS_CLUSTER=student-app-lab`، `ECS_SERVICE=student-app-lab-app`، `CONTAINER_NAME=app`؛ الأمر بعد `--` (default `/bin/sh`) |
| plugin | لو `session-manager-plugin` مش موجود → رسالة فيها رابط التثبيت و exit 69 |
| task | أول task `RUNNING` في الـ service (أو `--task <id>`) |
| preflight | `enableExecuteCommand` لازم `True` (غير كده بيقولك اعمل `--force-new-deployment`)، وحالة `ExecuteCommandAgent` لازم `RUNNING` (غير كده warning: الـ task لسه بيقوم أو الـ task role ناقصه `ssmmessages:*`) |
| exec | `aws ecs execute-command --interactive --command "<cmd>"` |

## 6) الـ Deploy

### 6.1 Migrations

```bash
cd infra/terraform/stacks/50-ecs-fargate
CMD=$(terraform output -raw migration_script_command)
cd ../../../..                                   # root الـ repo (المسار في الـ output نسبي)
eval "$CMD"                                       # = migrations للـ revision الحالية

export AWS_REGION=us-east-1 ECS_CLUSTER=student-app-lab ECS_SERVICE=student-app-lab-app
bash deploy/ecs/run-migrations.sh --task-definition student-app-lab-app:42    # revision معينة
bash deploy/ecs/run-migrations.sh --timeout 1800                              # migration تقيلة
```

**الترتيب الصح في أي pipeline** (ده اللي `deploy-ecs.yml` و `buildspec-deploy-ecs.yml` بيعملوه):

```bash
IMG=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<SHA7>
bash deploy/ecs/render-taskdef.sh live student-app-lab-app "$IMG" > td.json
TD_ARN=$(aws ecs register-task-definition --cli-input-json file://td.json --query taskDefinition.taskDefinitionArn --output text)
bash deploy/ecs/run-migrations.sh --task-definition "$TD_ARN" || { echo "stop: release not deployed"; exit 1; }
aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" --task-definition "$TD_ARN" >/dev/null
```

**نفس النمط لأي one-off command** — مثلاً seed بيانات الـ load test ([57](57-ecs-autoscaling-under-load.md)):

```bash
NET=$(terraform -chdir=infra/terraform/stacks/50-ecs-fargate output -raw run_task_network_configuration)
TD=$(aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].taskDefinition' --output text)
aws ecs run-task --cluster student-app-lab --task-definition "$TD" \
  --capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
  --network-configuration "$NET" --started-by seed \
  --overrides '{"containerOverrides":[{"name":"app","command":["php","artisan","db:seed","--class=LoadTestSeeder","--force"],"environment":[{"name":"LOADTEST_USERS","value":"20"}]}]}' \
  --query 'tasks[0].taskArn' --output text
```

### 6.2 ECS Exec

```bash
bash deploy/ecs/ecs-exec.sh                                   # /bin/sh في أول task شغال
bash deploy/ecs/ecs-exec.sh -- php artisan about
bash deploy/ecs/ecs-exec.sh -- php artisan migrate:status
bash deploy/ecs/ecs-exec.sh --task <TASK_ID> -- sh -c 'env | grep -E "^(APP_VERSION|DEPLOY_COLOR|DB_HOST)="'
bash deploy/ecs/ecs-exec.sh -- wget -qO- http://127.0.0.1:8080/ready
```

### 6.3 Debugging checklist (من الأسرع للأعمق)

| العَرَض | فين تبص | الأمر |
|---|---|---|
| الـ task مبيقومش | Stopped reason | `aws ecs describe-tasks --cluster student-app-lab --tasks <ID> --query 'tasks[0].{stop:stopCode,reason:stoppedReason,containers:containers[].{n:name,exit:exitCode,r:reason}}'` |
| `ResourceInitializationError` | الـ execution role / SSM ARN / الشبكة (public IP أو NAT) | `aws ssm get-parameters --names <NAME> --with-decryption` بنفس الـ ARN |
| `CannotPullContainerError` | الـ tag في ECR، شبكة الـ task لـ ECR | `aws ecr describe-images --repository-name student-app --image-ids imageTag=<TAG>` |
| الـ task بيقوم ويقع | logs الـ container | `aws logs tail /ecs/student-app-lab/app --since 15m --format short` |
| healthy في ECS بس unhealthy في الـ TG | `/ready` من جوه | `ecs-exec.sh -- wget -qO- http://127.0.0.1:8080/ready` (DB؟ unready flag؟ `SRE_FAULT_UNHEALTHY`؟) |
| events الـ service | آخر 10 events | `aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].events[:10].[createdAt,message]' --output table` |
| Logs Insights | errors آخر ساعة | `fields @timestamp, level_name, message \| filter level_name = "ERROR" \| sort @timestamp desc \| limit 50` |

## 7) التحقق (Verify)

```bash
bash deploy/ecs/run-migrations.sh; echo "exit=$?"            # exit=0 و "Nothing to migrate" لو مفيش جديد
aws ecs list-tasks --cluster student-app-lab --started-by migrations --desired-status STOPPED
bash deploy/ecs/ecs-exec.sh -- php artisan migrate:status | tail -5
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=ExecuteCommand \
  --max-results 5 --query 'Events[].[EventTime,Username]' --output table
# output الـ Exec session في نفس log group الـ app (stream جديد لكل session)
aws logs describe-log-streams --log-group-name /ecs/student-app-lab/app --order-by LastEventTime --descending \
  --max-items 5 --query 'logStreams[].logStreamName'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Migration فاشلة | branch تجريبي فيه migration بـ `DB::statement('SELECT * FROM no_such_table')` → CI → deploy | `run-migrations.sh` يطبع الـ exception و `✖ migrations failed: exit code 1` → الـ workflow يقف **قبل** `update-service`؛ الـ release القديم شغال |
| Release مش بيقوم | revision بـ `SRE_FAULT_BOOT_FAIL=true` → `run-migrations.sh --task-definition <ARN>` | الـ entrypoint بيرفض يقوم **حتى مع command override** → exit 1. يعني الـ migration step بيشتغل كـ smoke test مجاني للـ boot — وعشان كده drill الـ circuit breaker في [53](53-ecs-rolling-circuit-breaker.md) بيقفل الـ step ده (`run_migrations=false`) |
| Timeout | `--timeout 5` | `still RUNNING after 5s (left running on purpose)` و exit 1؛ الـ task يكمّل لوحده |
| Exec على task قديم | اقفل Exec → اعمل redeploy → افتحه تاني من غير redeploy → `ecs-exec.sh` | `ECS Exec is off for <id>. Start new tasks: ... --force-new-deployment` |
| Task role من غير ssmmessages | شيل الـ inline policy | `warning: ExecuteCommandAgent is ...` والـ execute-command يفشل بـ `TargetNotConnectedException` |
| Task role من غير `logs:*` | (console) شيل الـ statement `EcsExecSessionLogs` من الـ inline policy | الـ session بيشتغل عادي، بس مفيش stream جديد في `/ecs/student-app-lab/app` → فجوة audit صامتة. رجّعها بـ `terraform apply` |
| `initProcessEnabled=true` | `render-taskdef.sh live student-app-lab-app \| jq '.containerDefinitions[0].linuxParameters.initProcessEnabled=true'` → register → `run-migrations.sh` بالـ ARN | الـ container يقع بـ `s6-overlay-suexec: fatal: can only run as pid 1`. امسح الـ revision دي بعدها (deregister) عشان الـ `live` ميعملهاش copy |

## 9) الرجوع (Rollback)

- **الـ migrations مش بترجع أوتوماتيك** — ولا الـ circuit breaker ولا CodeDeploy بيلمسوا الداتابيز.
- `php artisan migrate:rollback` في production خطر (ممكن يمسح columns فيها data جديدة). الأفضل **roll-forward** بـ migration تصلّح.
- لو الـ schema اتبوظت فعلاً: RDS **point-in-time restore** لـ instance جديد ثم تحويل `DB_HOST` ([77](77-backup-and-dr.md)).
- الوقاية: expand/contract ([95](95-zero-downtime-db-migrations.md)) — الـ destructive step في release منفصل بعد ما الـ rollback window يخلص.

## 10) المسح (Teardown) ⚠️

مفيش موارد جديدة: الـ one-off tasks بتختفي من الـ console بعد ما تقف بفترة، والـ Exec sessions بتتقفل لوحدها. الـ teardown الحقيقي مع الـ stack ([51 §10](51-ecs-fargate-terraform.md)). امسح الـ revision التجريبية بتاعة `initProcessEnabled=true` بـ `aws ecs deregister-task-definition` (الـ `live` render بيشيل `SRE_FAULT_*` بس، مش أي تعديل تاني — فالـ revision دي لو فضلت أحدث واحدة هتتورّث). revisions الـ `BOOT_FAIL` مش محتاجة تنضيف.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| One-off task (0.5 vCPU / 1 GB، on-demand) | بالثانية بحد أدنى دقيقة ≈ أقل من سنت لكل migration |
| ECS Exec / Session Manager | مجاني (الـ logs لو فعّلتها بتتحاسب كـ CloudWatch Logs) |
| CloudTrail management events | أول trail مجاني |

## 12) أسئلة Interview

<details><summary>ليه الـ migration بتجري كـ task منفصل ومش init container أو entrypoint؟</summary>

عشان تجري **مرة واحدة** لكل release، **قبل** أي traffic، بـ exit code واحد يقرر مصير الـ deploy، وعلى capacity مضمونة (on-demand). الـ entrypoint بيجري مع كل replica (race + crash loop). ECS مفيهوش "init container" بمفهوم K8s Job لمرة واحدة؛ `dependsOn` بـ `SUCCESS` بيجري مع كل task برضه. المقابل في K8s: Helm `pre-upgrade` hook Job ([65](65-helm-chart.md)).

</details>

<details><summary>الـ migration task رجع STOPPED. إزاي تعرف إنه نجح؟</summary>

`containers[name=="app"].exitCode == 0`. الـ `lastStatus=STOPPED` و `stopCode=EssentialContainerExited` بيقولوا إن الـ container خلص بس. ولو الـ task مقمش أصلاً (secrets، pull) الـ exitCode بيبقى null — لازم يتعامل كفشل. وما تعتمدش على `aws ecs wait tasks-stopped` لوحده: بيستسلم بعد ~10 دقايق ومش بيتشيك على الـ exit code.

</details>

<details><summary>ليه migrations على on-demand حتى لو الـ service على Spot؟</summary>

Spot ممكن يتسحب بـ 2 دقيقة إنذار. migration اتقطعت في النص على MySQL = DDL جزئي (MySQL مش بيعمل transactional DDL)، ودي أسوأ حالة. فرق التكلفة لمهمة بتجري دقيقة واحدة تافه.

</details>

<details><summary>اشرح ECS Exec من ناحية الأمان مقارنةً بـ SSH.</summary>

مفيش بورت inbound، مفيش keys تتسرّب أو تتعمل rotate، الصلاحية بـ IAM (`ecs:ExecuteCommand` ممكن تتقفل بـ tags/cluster)، كل session في CloudTrail، والـ output بيتسجّل في CloudWatch Logs (عندنا: logging `DEFAULT` + صلاحيات `logs:*` في الـ task role على log group الـ app؛ أو S3 بـ `OVERRIDE`). المخاطر: أي حد معاه `ExecuteCommand` عنده shell بصلاحيات الـ task role وبيقدر يقرا الـ env (يعني الـ secrets) — فقيّدها و audit عليها، وفي production كتير بيقفلوها خالص أو بيفتحوها break-glass.

</details>

<details><summary>ليه `initProcessEnabled=false` مع إن AWS بتنصح بيه مع ECS Exec؟</summary>

النصيحة عشان الـ SSM agent بيعمل child processes ممكن تتحول zombies لو PID 1 مش بيعمل reap. هنا PID 1 هو S6 overlay، وده process supervisor بيعمل reap فعلاً، ومش بيقبل يشتغل غير كـ PID 1 — `tini` كان هيكسر الـ container. الدرس: الـ best practice ليها سبب؛ لو السبب متغطي بطريقة تانية، الالتزام الأعمى بيضر.

</details>

<details><summary>Migration طويلة (ساعة) — تعمل إيه؟</summary>

افصلها عن الـ deploy: online schema change (`pt-online-schema-change`/`gh-ost` أو MySQL `ALGORITHM=INSTANT/INPLACE` لما ينفع)، backfill على batches كـ job منفصل، والـ deploy نفسه يعمل expand سريع بس. وزوّد `--timeout` في `run-migrations.sh` وخلي timeout الـ pipeline أكبر منه، ومتقتلش الـ task لو الـ timeout خلص.

</details>

## 13) Checklist

- [ ] فاهم ليه `AUTORUN_LARAVEL_MIGRATION=false` وإيه مشكلة migrate عند الـ boot
- [ ] شغّلت `run-migrations.sh` وقريت الـ exit code والـ logs
- [ ] شغّلت migration من الـ console وعرفت فين الـ exit code
- [ ] ثبّت الـ session-manager-plugin ودخلت task بـ `ecs-exec.sh`
- [ ] فاهم ليه `initProcessEnabled=false` مع S6
- [ ] جرّبت migration فاشلة ووقفت الـ deploy
- [ ] مسحت الـ revisions التجريبية
