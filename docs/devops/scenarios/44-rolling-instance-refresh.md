# 44 — Rolling بـ ASG Instance Refresh

> **الهدف في سطر:** تعمل release لـ image جديدة على الـ fleet بـ **instance refresh** (rolling immutable): `put-parameter` للـ IMAGE_URI ثم `start-instance-refresh` — بإيدك من الـ Console والـ CLI، وأوتوماتيك بـ [`deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml) `strategy=instance-refresh` — وتفهم كل preference (min/max healthy، warmup، checkpoints، skip matching، alarms)، وليه الـ workflow عامل **`AutoRollback=false`** وبيرجّع بنفسه، وتجرّب release مش بيقوم (`SRE_FAULT_BOOT_FAIL`) وانت بتقيس بالـ probe.
> **المستوى:** Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** نفس [42](42-alb-asg-launch-template.md) (+ instance زيادة مؤقتاً مع Max healthy 150%)
> **بيعتمد على:** [42](42-alb-asg-launch-template.md) · [30 — CI](30-ci-github-actions.md) · [22 — قياس الـ downtime](22-recreate-and-measuring-downtime.md) · [95 — migrations](95-zero-downtime-db-migrations.md) · **الملفات في الـ repo:** [`.github/workflows/deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml) · [`modules/asg-app/main.tf`](../../../infra/terraform/modules/asg-app/main.tf) · [`modules/asg-app/user-data.sh.tftpl`](../../../infra/terraform/modules/asg-app/user-data.sh.tftpl) · [`stacks/40-ec2-alb-asg/outputs.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/outputs.tf) · [`docker/entrypoint.d/2-sre-boot-fault.sh`](../../../docker/entrypoint.d/2-sre-boot-fault.sh) · [`deploy/scripts/probe.sh`](../../../deploy/scripts/probe.sh)

## 1) الفكرة (Concepts)

**Instance refresh** = الـ ASG بيبدّل الـ instances على دفعات: يطلّع واحدة جديدة (بتبوت الـ image الجديدة من SSM)، يستنى تبقى healthy + warmup، يشيل قديمة (بعد الـ draining)، ويكرر. مفيش حاجة "بتتعمل deploy على" instance شغالة — immutable rolling.

| Preference | المعنى | في الـ repo |
|---|---|---|
| `MinHealthyPercentage` | أقل نسبة من الـ desired لازم تفضل InService + healthy | Terraform block: 50 · الـ workflow: input `min_healthy_percentage` (default **100**) |
| `MaxHealthyPercentage` | أقصى نسبة الـ group تكبر لها وقت الـ refresh (>100 = launch before terminate) | Terraform: 100 · الـ workflow: **min + 50** (بين 100 و 200) |
| `InstanceWarmup` | ثواني بعد ما الـ instance تبقى healthy قبل ما الـ refresh يكمّل | 120 (الـ default instance warmup بتاع الـ ASG) |
| `SkipMatching` | يتخطى الـ instances اللي مطابقة للـ desired configuration | **`false` إجباري هنا** — الـ LT متغيّرش، فلو `true` مفيش ولا instance هتتبدّل |
| `CheckpointPercentages` / `CheckpointDelay` | يقف عند نسب معينة (آخرها لازم 100) ويستنى (default ساعة) | مش مستخدم في الـ workflow — تمرين §6.1 |
| `AlarmSpecification` | لو alarm دخل `ALARM` → الـ refresh **Failed** (لحد 10 alarms؛ لازم تكون `OK` لحظة البدء) | `student-app-<env>-alb-5xx-ratio` + `student-app-<env>-<color>-unhealthy-hosts` |
| `AutoRollback` | يرجع للـ configuration المحفوظة قبل الـ refresh (محتاج **DesiredConfiguration**) | Terraform block: `true` · الـ workflow: **`false`** |
| `BakeTime` | انتظار في آخر الـ refresh قبل ما يتعلّم Successful | مش مستخدم |
| `StandbyInstances` / `ScaleInProtectedInstances` | يعمل إيه مع instances في Standby أو محمية من الـ scale-in | defaults |

### 1.1 Min/Max healthy بالأرقام (desired = 2)

| Min / Max | السلوك | الـ capacity أثناء الـ refresh | التكلفة |
|---|---|---|---|
| 50 / 100 (Terraform block) | terminate واحدة ← launch واحدة | بتنزل لـ **1** (نص الـ capacity) | مفيش زيادة |
| **100 / 150** (الـ workflow default) | launch واحدة زيادة (3) ← healthy + warmup ← terminate قديمة | مبتنزلش عن **2** أبداً | instance زيادة دقايق |
| 100 / 200 | launch 2 مرة واحدة | 2 → 4 → 2 | أسرع، ضعف الـ capacity مؤقتاً |

### 1.2 ليه `AutoRollback=false` في الـ workflow

من header الـ [`deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml): الـ release عايش في **SSM parameter بيتقري وقت الـ boot**، مش في الـ Launch Template. AWS auto rollback:
1. محتاج `DesiredConfiguration` في الـ request (الـ workflow مش بيبعته لأن الـ LT متغيّرش).
2. وحتى لو بعته، الـ rollback بيرجّع **الـ LT** — اللي متغيّرش أصلاً → الـ instances الـ "rollback" هتبوت **نفس الـ IMAGE_URI البايظ**.

فالـ workflow بيعمل الـ rollback بنفسه بشكل deterministic: `put_image <previous>` ثم refresh جديد **من غير alarm gate** (الـ rollback لازم يكمّل حتى والـ alarm اللي وقّفنا لسه شغال). الـ rollback الأوتوماتيك الحقيقي من AWS بيحصل لما الـ LT نفسه يتغيّر (AMI/user data — [43](43-golden-ami-packer.md)).

## 2) المعمارية (Architecture)

```text
 t0  put-parameter /student-app/lab/deploy/blue/IMAGE_URI = …/student-app:NEW
     start-instance-refresh  Min 100 / Max 150 / Warmup 120 / SkipMatching=false / Alarms[5xx, blue-unhealthy]
                                             desired=2 (old A, old B)
 t1  launch C  ──► user data: app.env + IMAGE_URI(NEW) → docker run → TG: initial → healthy (2×10s)
 t2  warmup 120s (C في الـ TG بياخد traffic؛ الـ refresh مستني)            A,B (OLD) + C (NEW)   ← mixed versions!
 t3  terminate A: deregister → draining 30s → shutdown (SIGQUIT, 30s)       B (OLD) + C (NEW)
 t4  launch D ... healthy + warmup                                          B + C + D
 t5  terminate B                                                            C + D (NEW)   → Successful
      ▲
      └─ أي alarm في ALARM → Failed → (workflow) put-parameter PREVIOUS → refresh تاني من غير alarms
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 40 شغال ([42](42-alb-asg-launch-template.md)) والـ migrations اتعملت.
- [ ] image جديدة في ECR (push على `master`/`main` → [`ci.yml`](../../../.github/workflows/ci.yml))، أو اعمل نفس الكود بـ SHA تاني.
- [ ] GitHub: `AWS_DEPLOY_ROLE_ARN` (bootstrap)، `APP_URL` على environment `lab`؛ اختياري `ASG_NAME_BLUE` و `REFRESH_ALARM_NAMES` (CONVENTIONS §9).
- الأدوات: `aws` · `gh` · `jq` · `bash` (Git Bash/WSL للـ probe).

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
export AWS_REGION=us-east-1
APP_URL=$(terraform output -raw app_url)
ACCT=$(aws sts get-caller-identity --query Account --output text)
REPO=$ACCT.dkr.ecr.us-east-1.amazonaws.com/student-app
P=/student-app/lab/deploy/blue/IMAGE_URI
aws ssm get-parameter --name $P --query Parameter.Value --output text           # الـ release الحالي
aws ecr describe-images --repository-name student-app --query 'sort_by(imageDetails,&imagePushedAt)[-5:].imageTags' --output text
```

## 4) الطريقة الأولى: AWS Console (يدوي)

1. **Systems Manager → Parameter Store → `/student-app/lab/deploy/blue/IMAGE_URI` → Edit** → Value: `<REPO>:<NEW_SHA>` → **Save changes**. (خد بالك: من اللحظة دي أي scale-out هيبوت الـ release الجديد.)
2. **EC2 → Auto Scaling groups → `student-app-lab-blue` → Instance refresh → Start instance refresh**:
   - **Instance replacement method: Launch before terminating** · Min healthy **100%** · Max healthy **150%**
   - Instance warmup: **120**
   - **Skip matching: ⬜ (اقفله!)** — الـ console بيفعّله افتراضياً، ومع LT متغيّرش الـ refresh هيخلص "Successful" في ثواني من غير ما يبدّل حاجة. أشهر غلطة في السيناريو ده.
   - Checkpoints (تمرين): ✅ Enable → 50% → delay 5 دقايق
   - CloudWatch alarms: ✅ `student-app-lab-alb-5xx-ratio` + `student-app-lab-blue-unhealthy-hosts`
   - Rollback settings: ⬜ auto rollback (هتفهم ليه في §1.2)
   → **Start instance refresh**.
3. راقب: التاب (Status / Percentage complete / Instances to update) + **Activity** + **Target groups → Targets** + الـ dashboard.

## 5) الطريقة التانية: CLI و GitHub Actions

### 5.1 الـ CLI (اللي الـ pipeline بيعمله)

```bash
NEW=<NEW_SHA>
PREV=$(aws ssm get-parameter --name $P --query Parameter.Value --output text)
aws ssm put-parameter --name $P --type String --value "$REPO:$NEW" --overwrite
RID=$(aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --strategy Rolling \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false,"AutoRollback":false,
                  "AlarmSpecification":{"Alarms":["student-app-lab-alb-5xx-ratio","student-app-lab-blue-unhealthy-hosts"]}}' \
  --query InstanceRefreshId --output text)
while :; do
  read -r ST PCT <<<"$(aws autoscaling describe-instance-refreshes --auto-scaling-group-name student-app-lab-blue \
      --instance-refresh-ids "$RID" --query 'InstanceRefreshes[0].[Status,PercentageComplete]' --output text)"
  echo "$(date +%T) $ST $PCT%"; case $ST in Successful|Failed|Cancelled|RollbackSuccessful|RollbackFailed) break;; esac; sleep 20
done
```

(النسخة الأقصر في `terraform output -raw release_commands` بـ `MinHealthyPercentage 50` و `InstanceWarmup 120` — وبتعتمد على defaults الـ API: `SkipMatching` default `false` في الـ CLI.)

> ⚠️ لو alarm من الاتنين `INSUFFICIENT_DATA` أو `ALARM` لحظة البدء، الـ API بيرفض الـ request. الـ workflow بيحل ده بـ `ok_alarms_json`: بيستخدم بس الـ alarms اللي `OK` ويطبع warning للباقي.

### 5.2 الـ workflow: `deploy-asg.yml strategy=instance-refresh`

```bash
gh workflow run deploy-asg.yml --ref devops-lab \
  -f strategy=instance-refresh -f image_tag=<NEW_SHA> -f target_color=auto \
  -f min_healthy_percentage=100 -f instance_warmup=120 -f run_migrations=true
gh run watch
```

| Step | بيعمل إيه |
|---|---|
| Validate inputs | `image_tag` (فاضي = SHA الـ commit) لازم regex و مش `latest`؛ `min_healthy_percentage` 0–100 |
| Configure AWS credentials (OIDC) | `AWS_DEPLOY_ROLE_ARN` — صلاحيات محددة: `PutParameter` على `/student-app/*/deploy/*`، `StartInstanceRefresh` على `student-app-*` ASGs… ([bootstrap](../../../infra/terraform/bootstrap/github-oidc.tf)) |
| Resolve the image in ECR | `describe-images` — لو الـ tag مش موجود: يقف قبل أي تغيير (guardrail ضد release بيبوت image مش موجودة) |
| Plan | `live` من أوزان الـ listener (لو المتغيرات موجودة، وإلا blue)؛ `target = live` في instance-refresh؛ `previous_image` = قيمة الـ parameter الحالية |
| Start the traffic probe | `probe.sh $APP_URL/ready` كل 0.2s في الخلفية |
| Run migrations once | على أول instance InService عن طريق SSM Run Command: `docker run --rm --env-file /opt/student-app/app.env <NEW> php artisan migrate --force` — **قبل** ما أي instance تخدم الـ release (لازم expand/contract — [95](95-zero-downtime-db-migrations.md)) |
| Release: instance refresh | لو الـ pointer = الـ image أصلاً → `unchanged`. لو الـ ASG desired = 0 → يحدّث الـ pointer بس. وإلا `put_image` → `start_refresh` (gates = `REFRESH_ALARM_NAMES` أو الافتراضي، بس اللي `OK`) → `wait_refresh` |
| ↳ فشل | `put_image PREVIOUS` → `start_refresh '[]'` → `outcome=rolled-back` + الـ job يفشل |
| Stop the probe / Smoke test / Job summary | الـ availability أثناء الـ release، `/ready` بعدها، جدول بالـ outcome والـ previous pointer |

## 6) الـ Deploy — release مع القياس

Terminal 1 (جهازك):

```bash
bash deploy/scripts/probe.sh "$APP_URL/ready" 0 0.2      # Ctrl+C في الآخر → summary
```

Terminal 2: §5.1 أو §5.2. Terminal 3 (اختياري، توزيع الإصدارات لحظة بلحظة):

```bash
k6 run -e BASE_URL="$APP_URL" -e RATE=10 -e DURATION=12m loadtest/k6/canary-watch.js
```

المفروض: الـ probe بيطلع الإصدار القديم ثم الاتنين مع بعض (mixed) ثم الجديد بس، و `failed : 0` (Min 100 + draining 30s + SIGQUIT graceful). المدة ~4 دقايق لكل instance (boot + 20s health + 120s warmup).

### 6.1 Checkpoints (canary "رخيص" بالـ instance refresh)

```bash
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --strategy Rolling \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false,
                  "CheckpointPercentages":[50,100],"CheckpointDelay":600,
                  "AlarmSpecification":{"Alarms":["student-app-lab-alb-5xx-ratio"]}}'
```

عند 50% الـ refresh بيقف 10 دقايق (نص الـ fleet على الجديد) — وقت تبص فيه على الـ dashboard، ولو مش عاجبك: `aws autoscaling cancel-instance-refresh --auto-scaling-group-name student-app-lab-blue` ثم رجّع الـ pointer و refresh تاني. الفرق عن [46](46-canary-weighted-target-groups.md): هنا النسبة = نسبة instances (خشنة: 50% مع 2 instances)، والـ "rollback" محتاج instances جديدة.

## 7) التحقق (Verify)

```bash
aws autoscaling describe-instance-refreshes --auto-scaling-group-name student-app-lab-blue --max-records 3 \
  --query 'InstanceRefreshes[].{id:InstanceRefreshId,status:Status,reason:StatusReason,start:StartTime,end:EndTime,prefs:Preferences}'
aws ssm get-parameter-history --name $P --query 'Parameters[-3:].[LastModifiedDate,Value,LastModifiedUser]' --output table
curl -s "$APP_URL/ready" | jq '{version,color}'
aws autoscaling describe-scaling-activities --auto-scaling-group-name student-app-lab-blue --max-items 6 \
  --query 'Activities[].[StartTime,Description]' --output table
```

## 8) اكسرها (Break it): تمرين على الأعطال

### 8.1 Image مش موجودة (عطل في الـ **image**)

```bash
aws ssm put-parameter --name $P --type String --value "$REPO:doesnotexist" --overwrite     # الـ workflow كان هيرفض ده
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --strategy Rolling \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false,"AutoRollback":false,
                  "AlarmSpecification":{"Alarms":["student-app-lab-blue-unhealthy-hosts"]}}'
```

المتوقع: الـ instance الجديدة بتعمل `retry docker pull` 10 مرات ثم الـ user data يخرج → مفيش container → unhealthy دقيقتين → alarm → refresh **Failed**. الـ probe: `failed : 0` (Min 100: القديمة لسه بتخدم). الرجوع: الـ pointer لـ `$PREV` + refresh (§9) — وده **بيصلّح** لأن العطل في الـ image.

### 8.2 `SRE_FAULT_BOOT_FAIL` (عطل في الـ **config**)

`2-sre-boot-fault.sh` في `/etc/entrypoint.d` بيخلّي الـ container يقفل نفسه لو `SRE_FAULT_BOOT_FAIL=true`. الـ user data بيقرا كل `/student-app/lab/app/*` لـ `app.env`، فالـ fault بيتحقن من SSM:

```bash
aws ssm put-parameter --name /student-app/lab/app/SRE_FAULT_BOOT_FAIL --type String --value true
aws ssm put-parameter --name $P --type String --value "$REPO:$NEW" --overwrite
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --strategy Rolling \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false,"AutoRollback":false,
                  "AlarmSpecification":{"Alarms":["student-app-lab-blue-unhealthy-hosts"]}}'
```

لاحظ (Session Manager على الـ instance الجديدة): `docker ps -a` → الـ container `Restarting` (الـ `--restart unless-stopped` بيعيده كل شوية)، و `docker logs student-app` → `SRE_FAULT_BOOT_FAIL=true -> refusing to start`، والـ cloud-init نفسه **نجح** (`docker run -d` رجع فوراً) — الـ health check بس هو اللي كشف.

**الدرس:** رجّع الـ pointer للـ `$PREV` و refresh → **لسه بايظ!** الـ fault في الـ config المشتركة، مش في الـ image. لازم تشيل الـ config الأول:

```bash
aws ssm delete-parameter --name /student-app/lab/app/SRE_FAULT_BOOT_FAIL
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --strategy Rolling \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false}'
```

والأخطر: طول ما الـ parameter موجود، **أي** scale-out (حتى لـ green، لأن الـ app path مشترك) هيبوت instances بايظة. الـ config جزء من الـ release ومحتاجة نفس الـ discipline (versioning، rollout، rollback).

| التمرين | المتوقع |
|---|---|
| نفس 8.1 بالـ workflow (`image_tag=doesnotexist`) | يفشل في "Resolve the image in ECR" قبل أي تغيير |
| Skip matching ✅ من الـ console | Successful في ثواني، 0 instances اتبدلت، والـ release الجديد هيظهر بس مع أول scale-out (= mixed fleet بالصدفة) |
| Min 50 / Max 100 | الـ probe: ممكن تشوف latency أعلى (instance واحدة شايلة كل الـ traffic)، والـ capacity نزلت للنص |
| alarm في `ALARM` قبل البدء | `start-instance-refresh` يرجّع error (والـ workflow يشيله من الـ gates بـ warning) |

## 9) الرجوع (Rollback)

```bash
aws autoscaling cancel-instance-refresh --auto-scaling-group-name student-app-lab-blue 2>/dev/null || true
aws ssm get-parameter-history --name $P --query 'Parameters[].[LastModifiedDate,Value]' --output text | tail -5
aws ssm put-parameter --name $P --type String --value "$PREV" --overwrite
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --strategy Rolling \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false}'
```

أو `gh workflow run deploy-asg.yml -f strategy=instance-refresh -f image_tag=<PREV_SHA> -f run_migrations=false` (الـ migrations مبترجعش — [95](95-zero-downtime-db-migrations.md)). لاحظ إن الـ rollback = refresh كامل (دقايق)، مش flip — ده التمن مقارنة بـ [45](45-bluegreen-two-asgs.md).

## 10) المسح (Teardown) ⚠️

مفيش resources جديدة. اتأكد: مفيش refresh شغال، الـ pointer على release سليم، و **`/student-app/lab/app/SRE_FAULT_*` ممسوحين**:

```bash
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[?contains(Name, `SRE_FAULT`)].Name'
```

ولو خلصت الـ track: `terraform destroy` في stack 40 ([42 §10](42-alb-asg-launch-template.md)).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| Max healthy 150% مع desired 2 | `t3.micro` زيادة (~$0.0104/ساعة + IPv4) لمدة الـ refresh (~10 دقايق) |
| Instances بتعمل boot loop (8.1/8.2) | كل instance بتتحاسب بالثانية (أقل حاجة 60s) — متسيبش refresh فاشل شغال |
| GitHub Actions | مجاني للـ public repos / ضمن الدقايق المجانية |

## 12) أسئلة Interview

<details><summary>Instance refresh مقابل rolling in-place (Ansible / CodeDeploy)؟</summary>

Refresh = immutable: instances جديدة، مفيش drift، الـ rollback = instances جديدة تانية (دقايق). In-place (Ansible [47](47-ansible-rolling-deploy.md)، أو CodeDeploy على نفس الـ ASG بـ `codedeploy_enabled = true` في stack 40 — [37](37-aws-codedeploy-ec2.md)) = نفس الـ instances، أسرع (pull + restart)، ومفيش capacity زيادة، بس الـ host ممكن يتراكم عليه state والـ rollback بيعتمد إن الـ host لسه سليم. الـ refresh بيستغل الـ ASG نفسه (health checks، warmup، alarms) من غير agent ولا SSH.

</details>

<details><summary>ليه AWS auto rollback مش هينفع هنا؟</summary>

لأنه بيرجع "آخر configuration محفوظة على الـ ASG" = الـ Launch Template version، ومحتاج DesiredConfiguration. الـ release عندنا في SSM بيتقري وقت الـ boot، والـ LT متغيّرش → الـ rollback هيبوت نفس الـ image البايظة. فالـ workflow بيرجّع الـ pointer ويعمل refresh تاني. بديل: تحط الـ image في الـ LT نفسه (user data/tag لكل release) → LT version لكل release → auto rollback يشتغل، بس الـ LT versions بتتكدّس و Terraform لازم `ignore_changes` على الـ LT.

</details>

<details><summary>إيه خطر الـ mixed versions أثناء الـ rolling؟</summary>

لدقايق، requests بتروح للقديم والجديد في نفس الوقت: الـ schema لازم تشتغل مع الاتنين (expand/contract — الـ migration بتجري قبل الـ refresh والقديم لسه بيخدم)، الـ sessions/cache لازم متوافقة (shape الداتا في الـ session)، والـ APIs متوافقة للـ clients. ده نفس قيد blue/green بس أطول.

</details>

<details><summary>Min healthy 100% / Max 150% — ليه مش دايماً كده؟</summary>

ده launch-before-terminate: الـ capacity مبتنزلش، بس محتاج instance quota و capacity زيادة (ممكن يفشل لو الـ type نادر أو Spot مش متاح)، وأبطأ شوية لو الـ group كبير. Min 90 (الـ default) أسرع مع groups كبيرة؛ Min 50 / Max 100 لما تكون مضغوط في الـ quota/التكلفة وقابل نزول الـ capacity.

</details>

<details><summary>إزاي تعرف إن الـ instance الجديدة "سليمة" قبل ما الـ refresh يكمّل؟</summary>

طبقات: ELB health (`/ready` 2×10s) → warmup 120s → alarms على مستوى الخدمة (5xx ratio، unhealthy hosts) طول الـ refresh → checkpoints للـ bake البشري/الأوتوماتيك. الـ health check لوحده مش كفاية: release بيرجّع 500 في صفحات معينة بيعدّي منه ([46](46-canary-weighted-target-groups.md)).

</details>

<details><summary>الـ config الغلط (SSM) بيتعامل معاه إزاي في immutable fleet؟</summary>

زي الـ code: version (parameter history أو AppConfig)، rollout تدريجي (تغيير الـ config + refresh مش تغيير صامت ينتظر أول scale-out)، و rollback بنفس الطريقة. في الـ lab كل الألوان بتقرا `/student-app/lab/app/*` — config مشتركة = blast radius كبير؛ في production افصل الـ config لكل لون/release أو ربطها بالـ release نفسه.

</details>

## 13) Checklist

- [ ] عملت refresh من الـ console وفهمت فخ Skip matching
- [ ] عملت release بالـ CLI (put-parameter + start-instance-refresh) والـ probe = 0 failures
- [ ] شغّلت `deploy-asg.yml strategy=instance-refresh` وقريت الـ job summary
- [ ] جرّبت checkpoints و cancel
- [ ] جرّبت image مش موجودة و `SRE_FAULT_BOOT_FAIL` وفهمت الفرق بين عطل في الـ image وعطل في الـ config
- [ ] رجّعت بالـ pointer + refresh، ومسحت أي `SRE_FAULT_*`
