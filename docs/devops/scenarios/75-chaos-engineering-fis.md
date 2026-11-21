# 75 — Chaos engineering بـ AWS FIS + Game day

> **الهدف في سطر:** تطبّق مبادئ الـ chaos engineering (hypothesis → steady state → blast radius → abort conditions → learnings)، تشغّل AWS FIS experiments (وقف نص الـ ECS tasks، terminate instance من الـ ASG، CPU stress، network latency) مرة من الـ Console ومرة بـ CLI/Terraform بـ stop conditions حقيقية، وتعمل chaos على مستوى التطبيق بالـ `SRE_FAULT_*` و `/sre-lab/*` — وتطلع بـ learnings مكتوبة.
> **المستوى:** Advanced · **الوقت:** ~4 ساعات (game day كامل) · **التكلفة التقريبية:** سنتات (FIS) + تكلفة الستاك
> **بيعتمد على:** [73](73-slo-error-budget-burn-rate.md) · [74](74-load-testing-k6.md) · [42](42-alb-asg-launch-template.md) أو [51](51-ecs-fargate-terraform.md) · **الملفات في الـ repo:** [`observability/fis/README.md`](../../../observability/fis/README.md) · [`ecs-stop-half-tasks.json`](../../../observability/fis/ecs-stop-half-tasks.json) · [`asg-terminate-one-instance.json`](../../../observability/fis/asg-terminate-one-instance.json) · [`ec2-cpu-stress.json`](../../../observability/fis/ec2-cpu-stress.json) · [`ec2-network-latency.json`](../../../observability/fis/ec2-network-latency.json) · [`infra/terraform/modules/fis/`](../../../infra/terraform/modules/fis) · [`stacks/50-ecs-fargate/main.tf`](../../../infra/terraform/stacks/50-ecs-fargate/main.tf)

## 1) الفكرة (Concepts)

الـ chaos engineering = **تجربة علمية** على النظام: "أنا متوقع إن لو X حصل، النظام هيعمل Y والمستخدمين هيشوفوا Z" — وبعدين تعمل X بشكل متحكم فيه وتقيس. مش "اكسر حاجات عشوائي". المبادئ (Principles of Chaos):

1. **Steady state hypothesis** بأرقام قابلة للقياس (الـ SLIs: availability، p95، healthy hosts).
2. **أحداث واقعية**: instance بيموت، task بيتوقف، CPU، network latency، AZ، dependency بطيئة.
3. **Blast radius صغير** الأول (`COUNT(1)`، `PERCENT(50)`، `PT5M`)، وبيكبر مع الثقة.
4. **Abort conditions** متقررة قبل البداية (stop conditions أوتوماتيك + معايير بشرية).
5. **Automate** و كرر (الـ regression في الـ resilience بيحصل بصمت).

| المصطلح | المعنى |
|---|---|
| FIS experiment template | targets + actions + stop conditions + role + logging |
| Action | الـ fault (`aws:ecs:stop-task`، `aws:ec2:terminate-instances`، `aws:ssm:send-command`...) |
| Target / selection mode | الموارد بالـ tags/params، و `COUNT(n)` / `PERCENT(p)` / `ALL` |
| Stop condition | CloudWatch alarm؛ لو دخل ALARM الـ experiment بيقف (ومش بيكمّل تاني) |
| `emptyTargetResolutionMode: fail` | لو مفيش targets مطابقة الـ experiment يفشل بدل ما "ينجح" على ولا حاجة |
| Game day | جلسة مخططة بأدوار بيتعمل فيها experiment أو أكتر والفريق بيتدرب على الاستجابة |

### 1.1 الـ templates

| Template (JSON في الـ repo) | Terraform (`modules/fis`) | الـ fault | السؤال |
|---|---|---|---|
| `ecs-stop-half-tasks.json` | `ecs_stop_tasks` (`ecs_stop_task_percent` = 50) | `aws:ecs:stop-task` على `PERCENT(50)` | الـ ALB بيبطّل يبعت للـ tasks الواقفة والـ service بيعوّضها قبل ما الـ SLO يحس؟ `desiredCount ≥ 2` وموزعين على AZs؟ |
| `asg-terminate-one-instance.json` | `asg_terminate_one` | `aws:ec2:terminate-instances` `COUNT(1)` بـ tag `aws:autoscaling:groupName` | health check → replacement → in service: قد إيه، وكام 502؟ |
| `ec2-cpu-stress.json` | `cpu_stress` (`cpu_stress_target_tags`) | `aws:ssm:send-command` + `AWSFIS-Run-CPU-Stress` (80%، 5 دقايق) على نص الـ instances | الـ CPU target tracking بيعمل scale out؟ (قارن بـ `autoscale-cpu.js` اللي بيحمّل من خلال التطبيق) |
| `ec2-network-latency.json` | — | `AWSFIS-Run-Network-Latency` (+200ms، 5 دقايق) على instance واحد | الـ latency burn-rate alert بيضرب؟ الـ timeouts/retries بتكبّر الأثر؟ |

لـ Fargate، CPU/network جوه الـ task محتاجين actions `aws:ecs:task-cpu-stress`/`task-network-latency` + SSM agent sidecar — **مش في المعمل**. لـ EKS: `aws:eks:pod-*` أو Chaos Mesh.

> 💡 **الأسماء:** الـ JSON templates بتستهدف الأسماء اللي الـ stacks بتعملها فعلاً: ASG **`student-app-lab-blue`** (stack 40 — لو شغّال على الـ green بس غيّرها لـ `student-app-lab-green`)، و ECS service **`student-app-lab-app`** في cluster `student-app-lab` (stack 50). الـ Terraform module بياخد الأسماء من الـ outputs مباشرة.

### 1.2 Stop conditions — أنهي alarm؟

| مصدر | Stop condition |
|---|---|
| JSON templates | `student-app-lab-slo-fast-burn` (composite)؛ و CPU stress كمان `student-app-lab-alb-latency-p95` |
| Terraform stack 50 (`enable_fis = true`) | `module.observability.alarm_arns["alb_5xx_ratio"]` = `student-app-lab-alb-5xx-ratio` |

نقطة senior: الـ **fast burn** محتاج الـ 1h window يعدّي 7.2% — في experiment مدته 5 دقايق على traffic عادي غالباً **مش هيضرب أبداً** حتى لو المستخدمين اتأذوا (الحسبة في [73 §1.5](73-slo-error-budget-burn-rate.md)). عشان كده stack 50 بيعيد استخدام `student-app-lab-alb-5xx-ratio` (> 1% على 5 دقايق) كـ stop condition: guardrail أسرع. استخدم الاتنين لو تقدر. ولو هتستخدم الـ composite كـ stop condition اتأكد في حسابك إن FIS بيقبله (الـ docs بتقول "CloudWatch alarm ARN" من غير تفصيل عن الـ composite)؛ لو لأ، استخدم child زي `student-app-lab-slo-burn-fast-5m` أو `alb-5xx-ratio`.

> ⚠️ **الـ ALB alarms مش بتفرّق بين drill و incident** ([CONVENTIONS §5](../CONVENTIONS.md) — known limitation): لو بتعمل app-level chaos على `/sre-lab/error` (أو `error-budget-burn.js MODE=lab`) ضد الـ ALB في نفس وقت FIS experiment، الـ 5xx بتاعته هتدخل `alb-5xx-ratio`/`slo-fast-burn` → الـ stop condition هيوقف الـ FIS experiment، و SNS هيبعت emails. افصل التجارب عن بعض، واعمل mute للـ SNS وقت الـ drills المقصودة.

## 2) المعمارية (Architecture)

```text
 k6 load.js (steady traffic) ──► ALB ──► TG blue ──► ECS tasks (student-app-lab-app) / ASG student-app-lab-blue
                                   │                       ▲
 CloudWatch alarms ◄── ALB metrics │                       │ aws:ecs:stop-task / aws:ec2:terminate-instances
   alb-5xx-ratio · slo-fast-burn   │                       │ aws:ssm:send-command (CPU / latency)
   alb-latency-p95                 │                       │
        │ ALARM                    │              ┌────────┴──────────────────────────┐
        └──────── stop condition ──┼────────────► │ AWS FIS experiment                 │
                                   │              │ role student-app-lab-fis           │
                                   │              │ logs → /aws/fis/student-app-lab    │
 Grafana / CloudWatch dashboard ◄──┘              └────────────────────────────────────┘
 scribe: timeline · observers: dashboards/alerts · operator: start/stop · facilitator: checklist
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 50 (ECS) أو stack 40 (ASG) شغال بـ **≥ 2** tasks/instances في **≥ 2 AZs** (الـ defaults: ECS `desired_count = 2`، ASG `desired_capacity = 2`).
- [ ] `alarm_email` متحدد وأكّدت الـ subscription (عشان تشوف الـ alarms بتوصل).
- [ ] traffic مستمر (k6) — من غير traffic الـ alarms مش هتشوف حاجة (`notBreaching`).
- [ ] لـ SSM actions: الـ instance profile فيه `AmazonSSMManagedInstanceCore` (stack 40 فيه) والـ instances ظاهرة في **Systems Manager → Fleet Manager**.
- الأدوات: `aws`، `terraform`، `k6`، `jq`.

## 4) الطريقة الأولى: AWS Console (يدوي) — ECS stop half tasks

### 4.1 الـ IAM role (لو مش عامل الـ Terraform)

1. **IAM → Roles → Create role → AWS service → FIS** (use case **FIS**) → Next.
2. Permissions: **AWSFaultInjectionSimulatorECSAccess** (و `…EC2Access` / `…SSMAccess` للتجارب التانية).
3. Name: `student-app-lab-fis` → Create. افتح **Trust relationships** وضيف condition `aws:SourceAccount` = حسابك (confused-deputy guard — زي الـ Terraform).
4. للـ logging: inline policy بـ `logs:CreateLogDelivery`، `logs:PutResourcePolicy`، `logs:DescribeResourcePolicies`، `logs:DescribeLogGroups` (نفس statement `ExperimentLogs` في الـ module).

### 4.2 الـ template

1. **CloudWatch → Log groups → Create** `/aws/fis/student-app-lab` retention 2 weeks.
2. **AWS FIS → Experiment templates → Create experiment template** → Account targeting: **this account**.
3. Description: الـ hypothesis (انسخها من الـ JSON). Name: `student-app-lab-ecs-stop-half-tasks`.
4. **Actions → Add action**: Name `stopTasks` · Action type **ECS → aws:ecs:stop-task** · Target: (هيعمل `Tasks-Target-1`).
5. **Targets → Edit** `Tasks-Target-1`: Resource type `aws:ecs:task` · Target method **Resource parameters**: cluster `student-app-lab`، service `student-app-lab-app` · Selection mode **Percent** = 50.
6. **Experiment options**: Empty target resolution mode = **Fail**.
7. **Service access**: Use an existing IAM role → `student-app-lab-fis`.
8. **Stop conditions → Add**: `student-app-lab-alb-5xx-ratio` (والـ `slo-fast-burn` لو اتقبل).
9. **Logs**: Send to CloudWatch Logs → `/aws/fis/student-app-lab`.
10. Tags: `Project=student-app`، `Env=lab`، `ManagedBy=console`، `Scenario=75` → **Create experiment template**.

(أسماء الأزرار في الـ FIS console ممكن تختلف شوية — المهم الحقول.)

### 4.3 التشغيل

1. اتأكد إن كل الـ alarms **OK** و الـ k6 شغال (§6.1).
2. Template → **Start experiment** → Tags `Scenario=75` → اكتب `start` للتأكيد.
3. تابع **Timeline** في صفحة الـ experiment، وفي tab تانية **ECS → service → Events** و **Target groups → Targets**.
4. الـ big red button: **Stop experiment**.

## 5) الطريقة التانية: CLI و Terraform

### 5.1 الـ JSON templates بالـ CLI

```bash
cd ~/src/StudentHub
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text); REGION=us-east-1
mkdir -p /tmp/fis
for f in observability/fis/*.json; do
  sed -e "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" -e "s/<REGION>/$REGION/g" "$f" > "/tmp/fis/$(basename "$f")"
done
grep -h '"service"\|groupName\|roleArn' /tmp/fis/*.json

TID=$(aws fis create-experiment-template --cli-input-json file:///tmp/fis/ecs-stop-half-tasks.json \
  --query 'experimentTemplate.id' --output text)
EID=$(aws fis start-experiment --experiment-template-id "$TID" --tags Scenario=75 --query 'experiment.id' --output text)
watch -n 5 "aws fis get-experiment --id $EID --query 'experiment.[state.status,state.reason]' --output text"
aws fis stop-experiment --id "$EID"                     # الزرار الأحمر
aws fis delete-experiment-template --id "$TID"          # cleanup
```

الـ JSON مافيهوش `logConfiguration` — ضيفه لو عايز experiment logs:

```json
"logConfiguration": { "logSchemaVersion": 2, "cloudWatchLogsConfiguration": { "logGroupArn": "arn:aws:logs:<REGION>:<ACCOUNT_ID>:log-group:/aws/fis/student-app-lab:*" } }
```

### 5.2 Terraform module `fis`

[`modules/fis/main.tf`](../../../infra/terraform/modules/fis/main.tf):

- **Role** `${name}-fis` = `student-app-lab-fis`: trust `fis.amazonaws.com` + `aws:SourceAccount`.
- **Policy least-privilege** (أضيق من الـ managed policies): `ecs:StopTask` على `task/<cluster>/*` بس؛ `ec2:TerminateInstances` بشرط `aws:ResourceTag/aws:autoscaling:groupName = <asg_name>` (مستحيل يمسح instance بره الـ ASG)؛ `ssm:SendCommand` على document `AWSFIS-Run-CPU-Stress` + instances؛ `ssm:ListCommands`/`CancelCommand`؛ والـ logs delivery.
- **Templates** بـ `count` حسب الـ inputs، كلهم `log_configuration` v2 لـ `/aws/fis/<name>` (retention 14)، والـ stop condition من `stop_condition_alarm_arn` (لو `null` → `source = "none"` — **مش recommended**).
- CPU stress: `duration` = مدة الـ document بالدقايق + 3 (وقت تثبيت `stress-ng` أول مرة).

**Stack 50:**

```bash
cd infra/terraform/stacks/50-ecs-fargate
terraform apply -var enable_fis=true -var image_tag=<SHA7>
terraform output -json fis_experiment_template_ids          # {"ecs_stop_tasks":"EXT…","asg_terminate_one":null,"cpu_stress":null}
aws fis start-experiment --experiment-template-id "$(terraform output -json fis_experiment_template_ids | jq -r .ecs_stop_tasks)" --tags Scenario=75
```

**Stack 40** مش بيستدعي الـ module لسه. إضافة مقترحة (**مش في الـ repo** — تحتاج كمان `variable "enable_fis"` في `variables.tf`):

```hcl
module "fis" {
  source = "../../modules/fis"
  count  = var.enable_fis ? 1 : 0

  name                     = local.name
  asg_name                 = local.asg_names["blue"]
  cpu_stress_target_tags   = { "aws:autoscaling:groupName" = local.asg_names["blue"] }
  stop_condition_alarm_arn = module.observability.alarm_arns["alb_5xx_ratio"]
}
```

### 5.3 Chaos على مستوى التطبيق (من غير FIS)

| الـ fault | إزاي | على أنهي platform |
|---|---|---|
| Release بيرجّع errors | `SRE_FAULT_ERROR_RATE=0.1` | compose: env وقت `up`؛ LB stack: `SLOT_ENV="SRE_FAULT_ERROR_RATE=0.1"`؛ ECS: `-var 'app_environment={SRE_FAULT_ERROR_RATE="0.1"}'` (بيوصل الـ tasks مع **الـ deploy الجاي** — `ignore_changes = [task_definition]`)؛ ASG: `aws ssm put-parameter --name /student-app/lab/app/SRE_FAULT_ERROR_RATE --type String --value 0.1 --overwrite` + instance refresh (لأن الـ user data بتقرا كل `/app/*`)؛ Helm: values |
| Release بطيء | `SRE_FAULT_LATENCY_MS=800` | نفس الطرق |
| Release unhealthy | `SRE_FAULT_UNHEALTHY=true` | → ALB يشيله، ECS/K8s/ASG rollback |
| Release مش بيقوم | `SRE_FAULT_BOOT_FAIL=true` | ECS circuit breaker ([53](53-ecs-rolling-circuit-breaker.md))، CrashLoopBackOff، refresh rollback ([44](44-rolling-instance-refresh.md)) |
| Instance واحد يتصرف | `POST /sre-lab/unready` على الـ instance (من جوه: `curl -X POST localhost:80/sre-lab/unready -H "X-Lab-Token: …"` عن طريق SSM) | الـ TG يشيله في ~20s (2 × 10s) — drain من غير restart |
| Saturation | `/sre-lab/cpu?ms=…`، `/sre-lab/memory?mb=128&hold_ms=5000` | autoscaling، OOM |
| DB bottleneck | `breakpoint.js TARGET=db-heavy` | `student-app-lab-rds-cpu` |

## 6) الـ Deploy — Game day كامل

### 6.1 الـ checklist (من [`observability/fis/README.md`](../../../observability/fis/README.md))

الأدوار: **facilitator** (بيمشي الـ checklist)، **operator** (start/stop)، **observers** (dashboards والـ alerts)، **scribe** (الـ timeline). لو لوحدك: البس الـ 4 قبعات بس اكتب كل واحدة.

1. **Hypothesis مكتوبة قبل أي حاجة:** *"لما نص الـ ECS tasks يقفوا، الـ ALB يلف حواليهم في أقل من 30s، ECS يرجّع الـ `desiredCount` في أقل من دقيقتين، الـ availability تفضل ≥ 99.5% و p95 < 300ms."*
2. **Steady state (10 دقايق):**
   ```bash
   k6 run -e BASE_URL=http://<ALB_DNS> -e LAB_TOKEN=<TOKEN> -e LOADTEST_USERS=20 -e VUS=10 -e DURATION=30m -e P95_MS=300 loadtest/k6/load.js
   ```
   سجّل الـ baseline: req/s، error ratio، p95، healthy hosts، عدد الـ tasks/instances. مفيش incident مفتوح، مفيش deploy شغال، والـ budget مش خلصان.
3. **Blast radius:** lab بس (`Env=lab`)، `PERCENT(50)` أو `COUNT(1)`، مدة محدودة، capacity check (≥ 2 في ≥ 2 AZs)، وبلّغ الناس.
4. **Abort conditions:** الـ stop condition alarms **OK** قبل البداية؛ معايير بشرية: availability < 99% لدقيقتين، p95 > 1s لـ 5 دقايق، أي data error، أو "مش فاهمين اللي بنشوفه"؛ و `aws fis stop-experiment --id …` جاهز في terminal.
5. **Run and observe:** الـ scribe يسجل: start، أول symptom، أنهي alert ضرب وإمتى، recovery، end. راقب ELB 5xx مقابل target 5xx، healthy hosts، ECS events/ASG activity، burn-rate panels، SNS، Logs Insights.
6. **Learnings خلال 48 ساعة** (blameless — template تحت).

### 6.2 أوامر المراقبة وقت الـ experiment

```bash
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app \
  --query 'services[0].[runningCount,desiredCount,events[:5].message]'
aws elbv2 describe-target-health --target-group-arn <TG_BLUE_ARN> \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table
aws autoscaling describe-scaling-activities --auto-scaling-group-name student-app-lab-blue --max-items 5 \
  --query 'Activities[].[StartTime,StatusCode,Description]' --output table
aws cloudwatch describe-alarms --alarm-name-prefix student-app-lab --state-value ALARM --query 'MetricAlarms[].AlarmName'
aws logs tail /aws/fis/student-app-lab --since 15m
```

### 6.3 Template للـ learnings

```markdown
# Game day — <التاريخ> — <اسم التجربة>
**Hypothesis:** …
**Result:** confirmed / refuted
| Metric | Expected | Actual |
|---|---|---|
| Time to detect (أول alert) | < 5m | … |
| Time to recover (healthy = desired) | < 2m | … |
| Errors served (ELB 5xx / target 5xx) | ≈ 0 | … / … |
| Error budget burned | < 1% | … |
| Alerts fired (name, severity, time) | alb-5xx-ratio فقط لو … | … |
**Timeline:** HH:MM start · HH:MM first symptom · …
**Surprises:** (أهم جزء)
**Action items:** | item | owner | due | (مثال: deregistration_delay، minimumHealthyPercent، alarm threshold، runbook update)
**Re-run scheduled:** <التاريخ>
```

### 6.4 تجارب مقترحة وتوقعاتها

| التجربة | المتوقع (لو التصميم سليم) | اللي ممكن يفاجئك |
|---|---|---|
| ECS stop 50% (2 tasks → 1) | الـ task بيعدّي بـ `DEACTIVATING` (deregister من الـ TG + `deregistration_delay` 30s) قبل الـ stop، فالمفروض 502 قليلة جداً؛ ECS يعوّض في ~1–2 دقيقة (pull + `startPeriod` 60s + 2 health checks) | الـ task الواحد الفاضل شايل كل الـ load؛ ولو شفت 502 كتير قارن `deregistration_delay` بـ `stopTimeout` (30) — والـ JSON مكتوب فيه SIGTERM بينما الـ ECS module بيقول Fargate بيحترم `STOPSIGNAL SIGQUIT`: اتأكد من لوج الـ task |
| ASG terminate 1 (2 → 1 ثم 2) | الـ instance اللي فاضل يشيل كل الـ load؛ replacement في دقايق (boot + docker pull + `health_check_grace_period`) | t3.micro واحد مش شايل الـ load → latency alarm؛ والـ hard terminate من غير drain = 502s |
| CPU stress 80% | الـ CPU target 50% يعدّي → scale out | الـ basic monitoring (5 دقايق، detailed مقفول) = scale out متأخر؛ و `ALBRequestCountPerTarget` مش هيتحرك (الـ load مش requests) |
| Network +200ms على instance واحد | p95 يطلع على نص الـ traffic → `alb-latency-p95` | الـ ALB بيوزّع round robin فالـ instance البطيء بياخد نفس النصيب (مفيش least outstanding requests افتراضياً) |

## 7) التحقق (Verify)

```bash
aws fis list-experiment-templates --query 'experimentTemplates[].[id,description]' --output table
aws fis list-experiments --query 'experiments[].[id,state.status,creationTime]' --output table
aws fis get-experiment --id <EXPERIMENT_ID> --query 'experiment.[state,stopConditions,actions]'
aws iam get-role --role-name student-app-lab-fis --query 'Role.AssumeRolePolicyDocument'
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Stop condition شغالة | قلّل `error_ratio_threshold` (مثلاً 0.001) + ECS stop | الـ alarm يدخل ALARM → الـ experiment `stopped` بـ reason فيه الـ alarm |
| مفيش targets | شغّل `asg-terminate-one-instance.json` واسم الـ ASG مش موجود (مثلاً stack 50 بس شغال، أو غيّر الـ tag لـ `student-app-lab-asg`) | `failed`: الـ targets مش resolved (`emptyTargetResolutionMode: fail`) — كويس، أحسن من "نجح على ولا حاجة" |
| Capacity = 1 | `desired_count=1` + `PERCENT(50)` | 50% من 1 = 0 (rounded down) → fail؛ و `COUNT(1)` = outage كامل — ده ليه الـ checklist بيقول ≥ 2 |
| Role ناقص | شيل `ecs:StopTask` | الـ action يفشل بـ AccessDenied في الـ experiment logs |
| Interface غلط | network latency بـ `Interface: eth0` على AL2023 | الـ command يفشل/مالوش أثر — AL2023 اسم الـ NIC `ens5` (`ip -br link`) |

## 9) الرجوع (Rollback)

- أثناء التجربة: `aws fis stop-experiment --id <ID>` (الـ terminate/stop مش بيترجعوا — الـ ASG/ECS هم اللي بيعوّضوا؛ الـ SSM stress/latency بيتلغوا).
- App-level: شيل الـ `SRE_FAULT_*` (compose `up`، `aws ssm delete-parameter --name /student-app/lab/app/SRE_FAULT_ERROR_RATE` + refresh، ECS deploy بالـ env القديمة).
- لو الـ tasks ما رجعتش: `aws ecs update-service --cluster student-app-lab --service student-app-lab-app --force-new-deployment`.

## 10) المسح (Teardown) ⚠️

```bash
for t in $(aws fis list-experiment-templates --query 'experimentTemplates[?tags.Scenario==`75`].id' --output text); do
  aws fis delete-experiment-template --id "$t"; done
aws logs delete-log-group --log-group-name /aws/fis/student-app-lab      # لو اتعمل بإيدك
terraform apply -var enable_fis=false                                     # stack 50
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي — راجع صفحة الأسعار) |
|---|---|
| FIS | ~$0.10 لكل action-minute (الـ templates مجاناً) |
| الـ faults نفسها | مجاناً — بس الـ replacements والـ scale-out اللي بيحصلوا بيتحاسبوا |
| CloudWatch Logs للـ experiments | سنتات |
| Game day كامل (ساعتين stack 50 + 4 experiments × 5 دقايق) | أقل من $1 فوق تكلفة الستاك |

## 12) أسئلة Interview

<details><summary>إيه الفرق بين chaos engineering و testing عادي؟</summary>

الـ testing بيثبت إن حاجة معروفة بتشتغل؛ الـ chaos experiment بيكتشف المجهول في نظام موزع كامل (configs، timeouts، health checks، autoscaling، human response) تحت ظروف واقعية. بيبدأ بـ hypothesis على الـ steady state بالأرقام، والنتيجة المهمة غالباً هي "المفاجآت".

</details>

<details><summary>إزاي تختار stop condition كويسة؟</summary>

alarm بيعكس أذى المستخدم (5xx ratio، latency) وبيضرب **بسرعة** على مدة التجربة. الـ burn rate fast alarm ممتاز للـ paging بس بطيء كـ guardrail لتجربة 5 دقايق (محتاج الـ 1h window يعدّي 7.2%). فالأحسن symptom alarm قصير (5xx > 1% على 5 دقايق) + معايير بشرية + الزرار الأحمر جاهز. ومتشغّلش من غير stop condition أبداً.

</details>

<details><summary>ECS stop-task مقابل terminate لـ EC2 instance — مين "أقسى"؟</summary>

`StopTask` على task جوه service ورا ALB بيمشي في الـ lifecycle العادي: `DEACTIVATING` (deregister + انتظار `deregistration_delay`) ثم stop signal ثم SIGKILL بعد `stopTimeout` — يعني فيه draining. الـ `aws:ec2:terminate-instances` على instance (من غير ما الـ ASG هو اللي قرر) = الـ host بيختفي والـ requests الشغالة بتموت، والـ ALB بيعرف بعد الـ health checks (2 × 10s) — ده الـ "hard failure" الحقيقي (الـ JSON نفسه بيقول "no graceful drain"). الاتنين مهمين: الأولى بتختبر الـ capacity والـ replacement، التانية بتختبر الأثر على المستخدم لما host يموت فجأة.

</details>

<details><summary>ليه تعمل chaos على مستوى التطبيق بالـ env لو عندك FIS؟</summary>

FIS بيكسر الـ infra (instances، tasks، network). أغلب الـ incidents الحقيقية release سيء: errors، بطء، crash on boot. الـ `SRE_FAULT_*` بتختبر الـ deploy safety (canary analysis، circuit breaker، refresh rollback، burn-rate alerts) بنفس الـ image ومن غير صلاحيات AWS خاصة — وتقدر تعملها محلياً وفي الـ CI.

</details>

<details><summary>إمتى تعمل chaos في production؟</summary>

بعد ما تكون: الـ SLOs والـ alerts بتشتغل، الـ rollback مجرّب، الـ experiments اتعملت في staging ونجحت، الـ blast radius صغير ومحسوب ضمن الـ error budget، والـ stop conditions شغالة. الـ production هو المكان الوحيد اللي فيه الـ traffic والـ data والـ configs الحقيقية — بس الثقة بتتبني بالتدريج. والـ experiment بيتحسب من الـ error budget.

</details>

## 13) Checklist

- [ ] كتبت hypothesis بأرقام قبل أول experiment
- [ ] عملت template من الـ Console (ECS stop) ومن الـ CLI (JSON بعد تبديل `<ACCOUNT_ID>`/`<REGION>`) ومن Terraform (`enable_fis`)
- [ ] شفت stop condition بتوقف experiment
- [ ] جرّبت fault على مستوى التطبيق (`SRE_FAULT_*`) وقارنته بـ FIS
- [ ] كتبت learnings بالـ template وفيها action items ليها owners
- [ ] مسحت الـ templates وقفلت `enable_fis`
