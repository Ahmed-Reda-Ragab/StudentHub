# 56 — Capacity providers و Fargate Spot

> **الهدف في سطر:** تفهم الـ capacity provider strategy (`base` و `weight`) بين `FARGATE` و `FARGATE_SPOT` وتحسب توزيع الـ tasks بإيدك، تتعامل مع الـ Spot interruption (إنذار دقيقتين، stop signal، graceful shutdown، deregistration)، تعرف إمتى تختار EC2 capacity providers بـ managed scaling (أو ECS Managed Instances)، وإيه المطلوب عشان تشغّل على Graviton/ARM64 — مع جدول تكلفة.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~2–3 ساعات · **التكلفة التقريبية:** أرخص من [51](51-ecs-fargate-terraform.md) (Spot لحد ~70% أقل على الـ compute)
> **بيعتمد على:** [51](51-ecs-fargate-terraform.md) · [53](53-ecs-rolling-circuit-breaker.md) · [11 — multi-arch](11-image-hardening.md) · **الملفات في الـ repo:** [`stacks/50-ecs-fargate/main.tf`](../../../infra/terraform/stacks/50-ecs-fargate/main.tf) · [`stacks/50-ecs-fargate/variables.tf`](../../../infra/terraform/stacks/50-ecs-fargate/variables.tf) · [`modules/ecs-fargate/main.tf`](../../../infra/terraform/modules/ecs-fargate/main.tf) · [`modules/ecs-fargate/variables.tf`](../../../infra/terraform/modules/ecs-fargate/variables.tf) · [`deploy/ecs/run-migrations.sh`](../../../deploy/ecs/run-migrations.sh) · [`observability/fis/ecs-stop-half-tasks.json`](../../../observability/fis/ecs-stop-half-tasks.json)

## 1) الفكرة (Concepts)

**Capacity provider** = "منين الـ compute". على Fargate عندك اتنين جاهزين: `FARGATE` (on-demand، مضمون) و `FARGATE_SPOT` (capacity فاضية عند AWS بخصم كبير، ممكن تتسحب). الـ **strategy** بتقول للـ scheduler يوزّع الـ tasks إزاي:

| الحقل | المعنى |
|---|---|
| `base` | أول N tasks **لازم** تروح على الـ provider ده (provider واحد بس في الـ strategy يقدر يبقى عنده `base > 0`) |
| `weight` | بعد ما الـ base يتملي، الـ tasks الزيادة بتتوزع بنسبة الـ weights |
| Default strategy (cluster) | بتتطبق على أي service/run-task من غير strategy صريحة |

### الحساب — strategy الـ stack (`use_fargate_spot = true`)

```hcl
{ capacity_provider = "FARGATE",      weight = 0, base = 1 }   # on-demand floor
{ capacity_provider = "FARGATE_SPOT", weight = 1, base = 0 }
```

| desired | FARGATE | FARGATE_SPOT | ملاحظة |
|---|---|---|---|
| 1 | 1 | 0 | الـ base بيتملي الأول |
| 2 (الـ default) | 1 | 1 | |
| 6 (max autoscaling) | 1 | 5 | weight 0 = مفيش tasks زيادة على on-demand |
| 6 بـ `FARGATE base=2 weight=1` + `SPOT weight=3` | 2 + 1 | 3 | الـ 4 الزيادة بتتوزع 1:3 |
| `use_fargate_spot = false` | كله | 0 | `{ FARGATE weight=1 base=0 }` |

> ⚠️ **مفيش fallback أوتوماتيك:** لو مفيش Spot capacity في الـ AZ، الـ tasks اللي نصيبها Spot بتفضل `PROVISIONING`/مش بتتعمل — ECS **مش** بيحوّلها لـ on-demand. الـ `base=1` على FARGATE هو ضمانك إن فيه task واحد على الأقل دايماً. للـ production: base أكبر (مثلاً = الحد الأدنى اللي يستحمل الـ load)، والباقي Spot.

### الـ Spot interruption — إيه اللي بيحصل بالظبط

1. AWS محتاجة الـ capacity → **إنذار دقيقتين** للـ task.
2. ECS بيبعت event `ECS Task State Change` (`stopCode = SpotInterruption`) لـ EventBridge، وبيبدأ يوقف الـ task: **deregister من الـ target group** (الـ ALB يعمل drain لمدة `deregistration_delay` = 30s)، وبعدين **الـ stop signal** للـ container.
3. الـ stop signal = `STOPSIGNAL` بتاع الـ image (`SIGQUIT` عندنا → PHP-FPM يخلّص الـ in-flight requests؛ Fargate بيحترم الـ `STOPSIGNAL` من ديسمبر 2025، قبلها كان `SIGTERM` دايماً) → بعد `stopTimeout` (30s، أقصى 120) → `SIGKILL`.
4. الـ service بيلاحظ إن الـ running < desired ويطلب task بديل حسب نفس الـ strategy (يعني Spot تاني لو متاح).

اللي لازم يكون صح عشان المستخدم ميحسش:

| الشرط | عندنا |
|---|---|
| ≥ 2 tasks في AZs مختلفة | `desired_count = 2`، `autoscaling_min = 2`، 2 AZ + AZ rebalancing |
| الـ app بيعمل graceful shutdown على الـ signal | PHP-FPM + `SIGQUIT` |
| `deregistration_delay + stopTimeout` < 120s | 30 + 30 = 60s ✅ |
| مفيش state محلي في الـ task | sessions + cache في MySQL (`database`) |
| الشغل اللي مينفعش يتقطع مش على Spot | الـ migrations على `FARGATE` on-demand ([`run-migrations.sh`](../../../deploy/ecs/run-migrations.sh): `CAPACITY_PROVIDER=FARGATE`) |

### EC2 capacity providers + managed scaling (concept)

بدل Fargate، تربط **Auto Scaling group** بالـ cluster كـ capacity provider:

| الإعداد | المعنى |
|---|---|
| Managed scaling (`targetCapacity` %) | ECS بيحسب metric `CapacityProviderReservation` ويكبّر/يصغّر الـ ASG عشان الـ tasks اللي في الانتظار تلاقي مكان. 100% = bin-packing كامل، أقل = headroom للـ scale-out السريع |
| Managed termination protection | ECS بيمنع الـ ASG يقفل instance عليها tasks |
| Managed draining | الـ instance اللي هتتقفل (scale-in/Spot/refresh) بتتحط `DRAINING` والـ tasks بتتنقل |
| ECS Managed Instances | خيار أحدث (2025): AWS بيدير الـ EC2 (provisioning، patching) وإنت تختار الـ instance requirements — بين Fargate و EC2 بتاعك |

**إمتى EC2 بدل Fargate؟**

| اختار EC2 / Managed Instances لما | اختار Fargate لما |
|---|---|
| الـ utilization عالي وثابت (bin-packing + Savings Plans/RIs على EC2 أرخص) | الـ load متغير، الفريق صغير، مش عايز تدير AMIs/patching |
| محتاج GPU، instance types معينة، local NVMe، أو أكبر من حدود Fargate | الـ tasks في حدود Fargate (لحد 16 vCPU / 120 GB، وجدول AWS الحالي فيه 32 vCPU كمان) |
| daemons (agents على كل host)، host networking، privileged | isolation على مستوى الـ task (micro-VM) مطلوب |
| startup أسرع لأن الـ image cached على الـ host | مش فارق ثواني الـ image pull |

### Graviton / ARM64

- الـ module فيه `cpu_architecture` (`X86_64` default أو `ARM64`) → `runtime_platform.cpu_architecture`. **مش متعرّض في stack 50** (تعدّل `module "ecs"`).
- Fargate ARM64 أرخص ~20% على الـ vCPU والـ GB، وغالباً أداء أحسن لكل دولار لـ PHP.
- **الشرط:** الـ image لازم تبقى **multi-arch** (manifest list فيه `linux/arm64`). `ci.yml` بيبني بـ `load: true` (platform واحدة، amd64) → task على ARM64 هيقع بـ `CannotPullContainerError ... no matching manifest` أو `exec format error`. الحل في [11](11-image-hardening.md): `docker buildx build --platform linux/amd64,linux/arm64 --push` (والـ base `serversideup/php` و `node:22-alpine` multi-arch).
- اتأكد إن `FARGATE_SPOT` مدعوم لـ ARM64 في الـ region بتاعك قبل ما تجمع الاتنين.

## 2) المعمارية (Architecture)

```text
 cluster student-app-lab
   capacity providers: FARGATE, FARGATE_SPOT
   default strategy  : FARGATE base=1 weight=0 · FARGATE_SPOT weight=1   (= استراتيجية الـ service)

 service student-app-lab-app  desired=2..6
   ┌──────────────── AZ a ────────────────┐   ┌──────────────── AZ b ────────────────┐
   │ task#1  FARGATE (on-demand floor)     │   │ task#2  FARGATE_SPOT                  │
   │                                       │   │ task#4  FARGATE_SPOT (scale-out)      │
   └───────────────────────────────────────┘   └───────────────────────────────────────┘
                                                   │ SpotInterruption (إنذار 2 دقيقة)
                                                   ▼
       EventBridge "ECS Task State Change" (stopCode=SpotInterruption)
       ALB deregister → drain 30s → SIGQUIT → stopTimeout 30s → SIGKILL
       service: running < desired → task بديل (FARGATE_SPOT لو فيه capacity)

 one-off: run-migrations.sh → capacityProvider=FARGATE دايماً (مش Spot)
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 50 شغال (`use_fargate_spot = true` default).
- [ ] k6 أو `probe.sh` للقياس، و `aws` + `jq`.
- [ ] للـ ARM64: image multi-arch في ECR ([11](11-image-hardening.md)) — غير كده اكتفي بالقراءة.

## 4) الطريقة الأولى: AWS Console (يدوي)

1. **ECS → Clusters → `student-app-lab` → Infrastructure**: Capacity providers `FARGATE` و `FARGATE_SPOT` + **Default capacity provider strategy**. لتعديل الـ default: **Update cluster** → Default capacity provider strategy.
2. **Service → Update service → Compute configuration → Capacity provider strategy → Use custom**: جرّب `FARGATE` base **2** weight **1** + `FARGATE_SPOT` base 0 weight **3** → ✅ **Force new deployment** (الـ strategy بتتطبق على الـ tasks الجديدة).
3. **Tasks tab**: عمود **Capacity provider** بيوري كل task على أنهي provider.
4. **EventBridge → Rules → Create rule** `student-app-lab-spot-interruptions` · Event pattern:

```json
{
  "source": ["aws.ecs"],
  "detail-type": ["ECS Task State Change"],
  "detail": {
    "clusterArn": [{ "suffix": "/student-app-lab" }],
    "stopCode": ["SpotInterruption"]
  }
}
```

   Target: SNS topic (`student-app-lab-alerts` من الـ observability module، أو CloudWatch log group) — كده تعرف كل مرة الـ Spot اتسحب. (لو الرسايل موصلتش، الـ SNS access policy محتاجة تسمح لـ `events.amazonaws.com` بـ `sns:Publish`.)

> ⚠️ أي تعديل في الـ strategy من الـ console = drift؛ الـ `terraform apply` الجاي هيرجّع `local.capacity_provider_strategy`.

## 5) الطريقة التانية: Infrastructure as Code (Terraform)

من [`stacks/50-ecs-fargate/main.tf`](../../../infra/terraform/stacks/50-ecs-fargate/main.tf):

```hcl
capacity_provider_strategy = var.use_fargate_spot ? [
  { capacity_provider = "FARGATE", weight = 0, base = 1 }, # on-demand floor
  { capacity_provider = "FARGATE_SPOT", weight = 1, base = 0 },
] : [
  { capacity_provider = "FARGATE", weight = 1, base = 0 },
]
```

ومن [`modules/ecs-fargate/main.tf`](../../../infra/terraform/modules/ecs-fargate/main.tf): `aws_ecs_cluster_capacity_providers` بيربط الاتنين وبيحط نفس الـ strategy كـ **default** (فأي `run-task` من غير strategy، أو CodeDeploy replacement task set من غير `CapacityProviderStrategy`، بياخدها). والـ service فيه `depends_on` على الـ cluster capacity providers (الـ strategy بتشاور على `FARGATE_SPOT`).

```bash
cd infra/terraform/stacks/50-ecs-fargate
terraform plan -var use_fargate_spot=false      # الـ service strategy تتغير → deployment جديد
terraform apply -var use_fargate_spot=false
```

**Graviton (تمرين تعديل كود — مش لازم تعمله apply):** في `module "ecs"` ضيف `cpu_architecture = "ARM64"`، وفي `ci.yml` ابني multi-arch. الـ `taskdef_source=repo` template ([`task-definition.json`](../../../deploy/ecs/task-definition.json)) كمان فيه `"cpuArchitecture": "X86_64"` — لازم يتغير معاه.

## 6) الـ Deploy

### 6.1 شوف التوزيع

```bash
CL=student-app-lab SVC=student-app-lab-app
aws ecs describe-services --cluster $CL --services $SVC --query 'services[0].capacityProviderStrategy'
aws ecs describe-tasks --cluster $CL \
  --tasks $(aws ecs list-tasks --cluster $CL --service-name $SVC --query 'taskArns' --output text) \
  --query 'tasks[].[taskArn,capacityProviderName,availabilityZone,lastStatus]' --output table
```

### 6.2 كبّر وشوف الـ base/weight

```bash
aws ecs update-service --cluster $CL --service $SVC --desired-count 6 >/dev/null
aws ecs wait services-stable --cluster $CL --services $SVC
# كرر أمر 6.1: المفروض 1 FARGATE + 5 FARGATE_SPOT
aws ecs update-service --cluster $CL --service $SVC --desired-count 2 >/dev/null   # الـ autoscaling min = 2
```

(الـ `desired_count` متجاهل في Terraform، والـ autoscaling ممكن يغيّره بعدك — ده متوقع.)

### 6.3 محاكاة الـ interruption (graceful stop)

مفيش طريقة رسمية "تسحب" Fargate Spot عند الطلب (أكشن FIS `aws:ec2:send-spot-instance-interruptions` لـ EC2 بس). أقرب محاكاة: نفس مسار الإيقاف (deregister → drain → stop signal) بـ `stop-task`:

```bash
URL=$(terraform -chdir=infra/terraform/stacks/50-ecs-fargate output -raw app_url)
bash deploy/scripts/probe.sh "$URL/ready" 180 0.1 &
SPOT_TASK=$(aws ecs describe-tasks --cluster $CL \
  --tasks $(aws ecs list-tasks --cluster $CL --service-name $SVC --query 'taskArns' --output text) \
  --query "tasks[?capacityProviderName=='FARGATE_SPOT'] | [0].taskArn" --output text)
aws ecs stop-task --cluster $CL --task "$SPOT_TASK" --reason "drill: simulated spot interruption" >/dev/null
wait
aws logs tail /ecs/student-app-lab/app --since 5m --format short | grep -iE "quit|finishing|exiting|shutdown" | tail
```

المتوقع: `probe.sh` → `failed : 0`، وتشوف في الـ logs PHP-FPM بيقفل graceful، والـ service يقوّم task بديل. (مع FIS: [`ecs-stop-half-tasks.json`](../../../observability/fis/ecs-stop-half-tasks.json) أو `enable_fis = true` — [75](75-chaos-engineering-fis.md).)

## 7) التحقق (Verify)

```bash
aws ecs describe-clusters --clusters student-app-lab --include SETTINGS \
  --query 'clusters[0].{cps:capacityProviders,default:defaultCapacityProviderStrategy}'
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app \
  --query 'services[0].events[:5].[createdAt,message]' --output table
# Cost Explorer بعد يوم: Service = "EC2 Container Service"، group by Usage type → SpotUsage مقابل on-demand
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Spot بس (من غير base) | console: `FARGATE_SPOT` weight 1 فقط + force deploy | شغال... لحد ما الـ Spot capacity تقل → ممكن **كل** الـ tasks تتسحب سوا = outage. ده سبب الـ on-demand floor |
| `stopTimeout` 120 + `deregistration_delay` 300 | عدّل الـ TG attribute | الإيقاف ممكن ياخد أكتر من الـ 2 دقيقة → في interruption حقيقي الـ SIGKILL بييجي قبل ما الـ drain يخلص |
| Migration على Spot | `bash deploy/ecs/run-migrations.sh --capacity-provider FARGATE_SPOT` | بيشتغل (مش ممنوع)، بس لو اتسحب في نص `ALTER` = schema نصها متعدل. الـ default `FARGATE` مقصود |
| ARM64 من غير multi-arch | revision بـ `runtimePlatform.cpuArchitecture = ARM64` + update-service | `CannotPullContainerError`/`exec format error` → circuit breaker rollback |
| strategy تغيّرت ومفيش force deploy | console update من غير force | الـ tasks الحالية متتحركش؛ الـ strategy بتتطبق على الـ tasks الجديدة بس |
| نص الـ tasks يقف مرة واحدة (FIS) | `sed -e 's/<ACCOUNT_ID>/'"$ACCT"'/g' -e 's/<REGION>/us-east-1/g' observability/fis/ecs-stop-half-tasks.json > /tmp/fis.json` ثم `aws fis create-experiment-template --cli-input-json file:///tmp/fis.json` و `aws fis start-experiment --experiment-template-id <ID>` (الـ role `student-app-lab-fis` موجود بس مع `enable_fis = true`؛ أو استخدم الـ template اللي Terraform عمله: `terraform output fis_experiment_template_ids`) | 1 من 2 tasks يتقفل (ممكن يكون الـ on-demand floor!) → الـ ALB يحوّل على الباقي والـ service يستبدل؛ `probe.sh` ممكن يشوف errors قليلة لو الـ task اللي فضل اتضغط. الـ stop condition (الـ JSON: `student-app-lab-slo-fast-burn` · Terraform: `student-app-lab-alb-5xx-ratio`) بيوقف الـ experiment لو المستخدمين اتأثروا ([75](75-chaos-engineering-fis.md)) |

## 9) الرجوع (Rollback)

- رجّع الـ strategy: `terraform apply` (بيرجّع `local.capacity_provider_strategy`) + الـ deployment بيحصل أوتوماتيك.
- لو الـ Spot capacity مش متاحة والـ service ناقص: `terraform apply -var use_fargate_spot=false` → كله on-demand.

## 10) المسح (Teardown) ⚠️

- امسح الـ EventBridge rule لو عملته، ورجّع أي تعديلات console.
- `aws ecs update-service --desired-count 2` لو سيبته 6.
- الـ stack: [51 §10](51-ecs-fargate-terraform.md).

## 11) التكلفة (Cost)

Task واحد 0.5 vCPU / 1 GB، us-east-1 (تقريبي — راجع صفحة الأسعار؛ الـ Spot سعره متغير):

| Option | /ساعة | /شهر (730 ساعة) | ملاحظة |
|---|---|---|---|
| Fargate x86 on-demand | ~$0.0247 (0.5×0.04048 + 1×0.004445) | ~$18 | |
| Fargate ARM64 (Graviton) on-demand | ~$0.0198 (0.5×0.03238 + 1×0.00356) | ~$14.4 | ~20% أرخص، محتاج multi-arch |
| Fargate Spot x86 | ~$0.007–0.008 | ~$5.5 | لحد ~70% خصم، ممكن يتسحب |
| الـ stack (1 on-demand + 1 Spot) | ~$0.033 compute | ~$24 | الـ default |
| 6 tasks: كلهم on-demand مقابل 1 + 5 Spot | ~$0.148 مقابل ~$0.062 | ~$108 مقابل ~$45 | وقت الـ peak |
| EC2 `t4g.small` (2 vCPU / 2 GB) كـ capacity provider | ~$0.0168 | ~$12 | يشيل ~3–4 tasks بالحجم ده لو bin-packed — بس إنت بتدفع لو فاضي وبتدير الـ AMI |

## 12) أسئلة Interview

<details><summary>اشرح `base` و `weight` بمثال: FARGATE base=2 weight=1، FARGATE_SPOT weight=3، و desired=10.</summary>

أول 2 على FARGATE (الـ base). الـ 8 الباقيين بيتوزعوا 1:3 → 2 FARGATE + 6 SPOT. الإجمالي 4 on-demand + 6 Spot. لو الـ Spot مش متاحة، الـ 6 مش هيتعملوا وهيفضل 4 شغالين — فالـ base لازم يغطي الحد الأدنى اللي يستحمل الـ load.

</details>

<details><summary>إيه اللي يحصل لما Fargate Spot task يتسحب؟ وإزاي تخلّي المستخدم ميحسش؟</summary>

إنذار دقيقتين → ECS يعمل deregister من الـ TG (drain) → stop signal (SIGQUIT هنا) → stopTimeout → SIGKILL → الـ service يستبدل. المطلوب: replicas ≥ 2 في AZs مختلفة، on-demand base، app stateless بيعمل graceful shutdown، drain + stopTimeout أقل من 120s، ومفيش شغل طويل مينفعش يتقطع على Spot (migrations، batch من غير checkpoint).

</details>

<details><summary>ليه مفيش fallback من Spot لـ on-demand أوتوماتيك؟ وتتعامل معاها إزاي؟</summary>

الـ capacity provider strategy مش بتعمل "try Spot then on-demand"؛ الـ weights ثابتة. الحلول: base on-demand كافي، مراقبة `RunningTaskCount < DesiredTaskCount` + الـ service events (`unable to place a task`)، و automation (EventBridge + Lambda أو runbook) يغيّر الـ strategy مؤقتاً، أو EC2 capacity provider بـ mixed instances policy (Spot diversification على أنواع كتير).

</details>

<details><summary>إمتى تنقل من Fargate لـ EC2 capacity providers؟</summary>

لما الحساب يقول: utilization ثابت عالي (bin-packing + Savings Plans)، GPUs أو instance features، daemons/sidecars على مستوى الـ host، أو startup time حرج (image cache). التمن: AMI patching، capacity planning (managed scaling بيساعد)، termination protection، draining. ECS Managed Instances حل وسط: AWS يدير الـ hosts وإنت تكسب مرونة الـ instance types.

</details>

<details><summary>عايز تنقل لـ Graviton. إيه الخطوات والمخاطر؟</summary>

(1) image multi-arch من الـ CI (buildx، base images تدعم arm64، أي native extensions/binaries تتبني للمعماريتين)، (2) tests على arm64 (runner arm أو QEMU)، (3) `cpuArchitecture = ARM64` في الـ task definition، (4) deploy تدريجي (canary) ومقارنة latency/CPU. المخاطر: dependency مالهاش arm64، فرق أداء في extension معينة، الـ build أبطأ بـ QEMU. المكسب: ~20% أرخص وأداء/دولار أحسن غالباً.

</details>

<details><summary>Container Insights/Cost — إزاي تثبت إن الـ Spot وفّر فعلاً؟</summary>

Cost Explorer: خدمة ECS، group by Usage type (Fargate Spot vs on-demand vCPU/GB-hours)، أو Cost and Usage Report بالـ tags (`Project`، `Scenario`) — الـ `propagate_tags = "SERVICE"` و managed tags بيخلّوا الـ tasks متعلّمة. وقارن بـ interruption count من EventBridge عشان تعرف التمن التشغيلي.

</details>

## 13) Checklist

- [ ] حسبت توزيع الـ tasks لـ desired 1/2/6 مع strategy الـ stack
- [ ] شفت `capacityProviderName` لكل task وكبّرت لـ 6
- [ ] عملت EventBridge rule للـ SpotInterruption
- [ ] حاكيت interruption بـ `stop-task` وقست 0 failures
- [ ] فاهم ليه الـ migrations على FARGATE
- [ ] فاهم شروط Graviton (multi-arch) وإمتى EC2 capacity providers
- [ ] رجّعت كل حاجة
