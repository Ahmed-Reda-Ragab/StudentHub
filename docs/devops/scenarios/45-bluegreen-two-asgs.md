# 45 — Blue/Green بـ اتنين ASG + listener switch

> **الهدف في سطر:** تشغّل لونين كاملين (ASG + target group لكل لون) ورا نفس الـ ALB، تجهّز الـ idle على الـ release الجديد وهو مش واخد traffic، وتحوّل الأوزان **100/0 → 0/100** في call واحد، و rollback **فوري** — بطريقتين: Terraform (tfvars + apply) و CI ([`deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml) `strategy=bluegreen-switch` + `listener_weights_managed_externally`) — وتفهم مين بيملك الأوزان (drift)، تمن الـ capacity المضاعفة، و `scale_down_old`.
> **المستوى:** Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** نفس [42](42-alb-asg-launch-template.md) + لون تاني (2 × `t3.micro` ≈ +$0.75/يوم وهو شغال — تقريبي، راجع صفحة الأسعار)
> **بيعتمد على:** [42](42-alb-asg-launch-template.md) · [44](44-rolling-instance-refresh.md) · [23 — Blue/Green على سيرفر واحد](23-bluegreen-single-host.md) · **الملفات في الـ repo:** [`modules/alb/main.tf`](../../../infra/terraform/modules/alb/main.tf) · [`stacks/40-ec2-alb-asg/main.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/main.tf) · [`stacks/40-ec2-alb-asg/variables.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/variables.tf) · [`.github/workflows/deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml) · [`modules/observability/main.tf`](../../../infra/terraform/modules/observability/main.tf)

## 1) الفكرة (Concepts)

نفس فكرة [23](23-bluegreen-single-host.md) بس على مستوى الـ infra: بدل container-ين ورا nginx، عندك **ASG blue + TG blue** و **ASG green + TG green**، والـ "router" هو الـ **default action الـ weighted** بتاع الـ listener. الـ switch = `modify-listener` (ثانية واحدة، الـ ALB بيطبّقه على كل request جديد)، والـ rollback = نفس الـ call بالعكس — **مفيش instances بتبوت**.

| المصطلح | المعنى |
|---|---|
| Live / Idle | اللون اللي وزنه أعلى (الـ workflow بيحسبه كده) / اللي هنعمل عليه deploy |
| Prepare idle | IMAGE_URI بتاع الـ idle = الجديد → refresh (أو scale من 0) → كل الـ targets healthy |
| Switch | `blue=0 green=100` (أو العكس) |
| Bake | فترة بعد الـ switch بنراقب فيها الـ alarms والقديم لسه شغال |
| `scale_down_old` | بعد النجاح: `min=0 desired=0` للقديم (توفير، بس الـ rollback محتاج scale-up الأول) |
| Ownership | مين يملك الأوزان: **Terraform** (tfvars) ولا **الـ CI** (`listener_weights_managed_externally = true`) |

### 1.1 مين يملك الأوزان؟ (أهم قرار في السيناريو)

الـ [alb module](../../../infra/terraform/modules/alb/main.tf) فيه **listener-ين بديلين** بـ `count` (لأن Terraform مينفعش يعمل `ignore_changes` بشرط):

| `listener_weights_managed_externally` | الـ resource | الأوزان بتيجي منين | لو الـ CI غيّرها |
|---|---|---|---|
| `false` (default) | `aws_lb_listener.http` / `https` | `blue_weight` / `green_weight` في tfvars | **أول `terraform apply` يرجّعها** = rollback صامت لـ production (drift) |
| `true` | `aws_lb_listener.http_external` / `https_external` بـ `ignore_changes = [default_action]` | Terraform بيعملها **مرة**، وبعدين الـ CI (`modify-listener`) | Terraform مبيلمسهاش |

⚠️ تغيير الـ flag = **destroy + create للـ listener** (resource تاني): ثواني connection refused على الـ port، و **ARN جديد** (لازم تحدّث `ALB_LISTENER_ARN` في GitHub). اعمله مرة واحدة في الأول، مش في نص deploy. نسخة الـ `*_external` فيها نفس الـ stickiness block، بس بسبب `ignore_changes = [default_action]` الـ `stickiness_duration` بيتطبّق **وقت إنشاء الـ listener بس** — تغييره بعدين بيبقى بالـ CLI ([46](46-canary-weighted-target-groups.md)).

### 1.2 قيود لازم تعرفها

- **الداتابيز مشتركة**: الـ migration بتجري مرة قبل الـ switch بالـ image الجديدة والقديم لسه بيخدم، والقديم فاضل للـ rollback → expand/contract إجباري ([95](95-zero-downtime-db-migrations.md)).
- **الـ sessions** في الداتابيز + نفس `APP_KEY` (من SSM لكل الألوان) → المستخدم مش بيعمل logout لما ينتقل.
- **الـ config مشتركة** (`/student-app/lab/app/*` لكل الألوان) — تغيير config مش "لون".
- **Capacity parity**: الـ idle ليه scaling policies خاصة بيه؛ ممكن يكون على `min_size` (1) والـ live على 4. لو حوّلت 100% على لون فيه instance واحدة = overload. الـ workflow بيعمل scale بس لو الـ idle على **0** (`want = desired_live`)؛ لو الـ idle على 1 هيفضل 1. **قارن الـ desired قبل الـ switch** (§6).
- **الـ green IMAGE_URI** بيتعمل seed من `image_tag` الأصلي (أول apply) — مش من الـ release الحالي بتاع blue.

## 2) المعمارية (Architecture)

```text
                         ALB :80/:443  default action = forward (weighted)
                            ┌──────────────────────────┴──────────────────────────┐
                    weight 100 → 0                                        weight 0 → 100
                 TG student-app-lab-blue                               TG student-app-lab-green
                 ▲ ASG student-app-lab-blue                            ▲ ASG student-app-lab-green (green_enabled)
                 │  /student-app/lab/deploy/blue/IMAGE_URI = v1         │  /student-app/lab/deploy/green/IMAGE_URI = v2
                 │  DEPLOY_COLOR=blue                                   │  DEPLOY_COLOR=green
                 └──────────────── SG student-app-lab-app (مشترك) ──────┴──► RDS (مشترك) · SSM app/* (مشترك)

 deploy-asg.yml bluegreen-switch:
   plan(live من الأوزان) → migrate(NEW، مرة) → prepare idle (put IMAGE_URI + refresh | scale 0→N) → wait_healthy
   → route_to idle 100 → bake: watch [alb-5xx-ratio, <idle>-unhealthy-hosts] BAKE_SECONDS
        ALARM → route_to live 100 (rollback ثانية)        OK → released [→ scale_down_old: min=0 desired=0]
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 40 شغال ([42](42-alb-asg-launch-template.md))، و [44](44-rolling-instance-refresh.md) مفهوم.
- [ ] GitHub variables: `ALB_LISTENER_ARN`، `TG_BLUE_ARN`، `TG_GREEN_ARN` (stack 40 outputs)، `APP_URL` (env `lab`)، `AWS_DEPLOY_ROLE_ARN`.
- [ ] max_size لكل لون ≥ desired بتاع الـ live (default 4).

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
export AWS_REGION=us-east-1
APP_URL=$(terraform output -raw app_url)
L=$(terraform output -raw listener_arn)
TGB=$(terraform output -json target_group_arns | jq -r .blue)
TGG=$(terraform output -json target_group_arns | jq -r .green)
REPO=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com/student-app
weights() { aws elbv2 describe-listeners --listener-arns "$L" \
  --query 'Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups[].[TargetGroupArn,Weight]' --output text | sed "s#$TGB#blue#;s#$TGG#green#"; }
weights
```

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 لون green

1. **Launch templates → Create launch template** → Name `student-app-lab-green` → **Source template**: `student-app-lab-blue` (بيملا كل الحقول) → في User data غيّر سطرين: `IMAGE_PARAM="/student-app/lab/deploy/green/IMAGE_URI"` و `DEPLOY_COLOR="green"` · Resource tags: `Color=green`، `Name=student-app-lab-green` → **Create**.
2. **SSM**: `aws ssm put-parameter --name /student-app/lab/deploy/green/IMAGE_URI --type String --value "$REPO:<NEW_SHA>"`.
3. **Auto Scaling groups → Create** → `student-app-lab-green` بالـ LT ده → نفس الـ subnets → Attach to TG **`student-app-lab-green`** → ELB health checks، grace 120 → **Desired = desired بتاع blue**، Min 1، Max 4 → Create.
4. استنى **Target groups → `student-app-lab-green` → Targets** كلها `healthy`.

### 4.2 اختبر green قبل الـ switch (من غير ما تلمس المستخدمين)

**Listeners → HTTP:80 → Rules → Add rule** → Name `test-green` → Condition **HTTP header** `X-Color` = `green` → Action: Forward to `student-app-lab-green` → Priority **10**:

```bash
curl -s "$APP_URL/ready" | jq -r .color                       # blue (المستخدمين)
curl -s -H 'X-Color: green' "$APP_URL/ready" | jq -r .color   # green (انت بس)
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Color: green' "$APP_URL/login"
```

(الـ rule ده مش في الـ Terraform module — زي الـ test listener rule في ECS native blue/green [55](55-ecs-native-bluegreen-linear-canary.md). امسحه بعد التجربة.)

### 4.3 الـ switch والـ rollback

**Listeners → HTTP:80 → Edit listener** (أو Default action → Edit) → الأوزان: blue **0**، green **100** → **Save changes**. للـ rollback: نفس الشاشة 100/0. شغّل `version-split.sh` وانت بتغيّر (§7).

## 5) الطريقة التانية: Infrastructure as Code

### 5.1 الـ Terraform way (tfvars بتملك الأوزان)

```bash
# 1) terraform.tfvars:  green_enabled = true   (blue_weight = 100, green_weight = 0 لسه)
terraform plan -out=tfplan        # + module.asg_green[0] (LT, ASG, IMAGE_URI param, policies) + alarm green-unhealthy-hosts
terraform apply tfplan

# 2) green اتولد على الـ seed (image_tag)، مش على release الـ blue. حطه على الجديد:
aws ssm put-parameter --name /student-app/lab/deploy/green/IMAGE_URI --type String --value "$REPO:<NEW_SHA>" --overwrite
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-green --strategy Rolling \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false}'
aws elbv2 describe-target-health --target-group-arn "$TGG" --query 'TargetHealthDescriptions[].TargetHealth.State'

# 3) الـ switch:  blue_weight = 0, green_weight = 100
terraform plan -out=tfplan        # لازم يبان: ~ module.alb.aws_lb_listener.http[0] (default_action) بس
terraform apply tfplan
weights
```

الـ rollback = رجّع الأوزان في tfvars + apply (~20–40 ثانية مع الـ refresh والـ plan، مش ثانية). التمن: الـ deploy محتاج صلاحيات Terraform كاملة (أو `terraform.yml` بـ approval — [92](92-terraform-in-ci.md)).

### 5.2 الـ CI way (`deploy-asg.yml` بيملك الأوزان)

```bash
# مرة واحدة: سلّم الأوزان للـ CI (recreate للـ listener!)
# terraform.tfvars:  green_enabled = true   listener_weights_managed_externally = true
terraform plan -out=tfplan        # -/+ listener: http[0] → http_external[0]  (+ نفس rule الـ /metrics)
terraform apply tfplan
gh variable set ALB_LISTENER_ARN --body "$(terraform output -raw listener_arn)"   # الـ ARN اتغيّر

# كل release:
gh workflow run deploy-asg.yml --ref devops-lab \
  -f strategy=bluegreen-switch -f image_tag=<NEW_SHA> -f target_color=auto \
  -f bake_seconds=300 -f run_migrations=true -f scale_down_old=false
gh run watch
```

| Step | بيعمل إيه في `bluegreen-switch` |
|---|---|
| Plan | `weight_of blue/green` من الـ listener → `live` = الأعلى؛ `target = idle` (`auto`)؛ لو `target == live` → يقف (`target the idle color`) |
| Migrations | مرة على instance InService (الـ live أولاً) بالـ image الجديدة |
| Prepare the idle color | `put_image idle NEW` → لو desired الـ idle = 0: `set-desired-capacity` = desired الـ live (أو 1) — وإلا refresh بـ gate `<idle>-unhealthy-hosts`؛ فشل → الـ pointer يرجع و `live color untouched` → `wait_healthy idle want 900` |
| Release: blue/green switch | `route_to idle 100` (بيحافظ على باقي إعدادات الـ action زي الـ stickiness) → يسأل `/ready` 10 مرات ويطبع الألوان → `watch_alarms BAKE_SECONDS CANARY_ALARM_NAME <idle>-unhealthy-hosts` → ALARM: `route_to live 100` + `outcome=rolled-back` |
| Scale the old color down | لو `scale_down_old=true`: `update-auto-scaling-group --min-size 0 --desired-capacity 0` للقديم |
| Job summary | جدول الأوزان بالوقت + الـ availability من الـ probe + "copy the final weights into tfvars" |

> 💡 الـ summary دايماً بيقول "انسخ الأوزان لـ tfvars". مع `listener_weights_managed_externally = true` ده مش ضروري (Terraform بيتجاهلها)، بس مفيد كـ documentation؛ مع `false` **إجباري** وإلا الـ apply الجاي يرجّع الـ traffic.

## 6) الـ Deploy — switch مع القياس

```bash
# قبل الـ switch: capacity parity
for c in blue green; do echo "$c desired=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-$c \
  --query 'AutoScalingGroups[0].DesiredCapacity' --output text)"; done
# لو الـ idle أقل: aws autoscaling set-desired-capacity --auto-scaling-group-name student-app-lab-green --desired-capacity <N>

# Terminal 1: الـ probe
bash deploy/scripts/probe.sh "$APP_URL/ready" 0 0.1
# Terminal 2: الـ switch (أي طريقة من §4.3 / §5.1 / §5.2)، أو يدوي بالـ CLI:
aws elbv2 modify-listener --listener-arn "$L" --default-actions \
  "[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[{\"TargetGroupArn\":\"$TGB\",\"Weight\":0},{\"TargetGroupArn\":\"$TGG\",\"Weight\":100}]}}]" >/dev/null
weights
```

المفروض: الـ probe بيطلع `v1 (blue)` ثم `v2 (green)` من غير ولا failure (الـ requests الشغالة على blue بتكمّل، والجديدة بتروح green). (الـ `modify-listener` بالـ JSON ده بيشيل أي stickiness config — الـ workflow بيحافظ عليها بـ `jq`.)

## 7) التحقق (Verify)

```bash
weights
bash deploy/scripts/version-split.sh "$APP_URL/ready" 50                 # 100% green
aws elbv2 describe-target-health --target-group-arn "$TGB" --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])'
aws elbv2 describe-target-health --target-group-arn "$TGG" --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])'
aws cloudwatch describe-alarms --alarm-names student-app-lab-alb-5xx-ratio student-app-lab-green-unhealthy-hosts \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
terraform plan        # مع managed_externally=false: لازم يطلب يرجّع الأوزان لو متحدّثتش tfvars → ده الـ drift
```

## 8) اكسرها (Break it): تمرين على الأعطال

الـ faults بتتحقن من `/student-app/lab/app/*` (مشتركة بين الألوان) → التكنيك: حط الـ parameter، خلّي الـ idle يبوت، **وامسحه أول ما الـ idle instances تقوم** (الـ live مبيتأثرش لأنه قرا `app.env` وقت الـ boot بتاعه؛ الخطر الوحيد scale-out للـ live في الشباك ده).

| التمرين | الأمر | المتوقع |
|---|---|---|
| Idle مش بيبقى healthy | `aws ssm put-parameter --name /student-app/lab/app/SRE_FAULT_UNHEALTHY --type String --value true` → شغّل الـ workflow → بعد ~3 دقايق `aws ssm delete-parameter --name /student-app/lab/app/SRE_FAULT_UNHEALTHY` | الـ refresh بتاع green يفشل على `green-unhealthy-hosts` → `refresh of idle … - live color untouched` (أو `never reached N healthy targets`). الـ probe = 0 failures — الـ switch محصلش أصلاً |
| Release بيرجّع 500 (الـ health checks ناجحة) | نفس التكنيك بـ `SRE_FAULT_ERROR_RATE=0.5` + traffic على `/login` (`bash deploy/scripts/probe.sh "$APP_URL/login" 0 0.05`) | الـ switch بيحصل (الـ `/ready` سليم) → 50% من الصفحات 500 لـ **كل** المستخدمين → الـ alarm `alb-5xx-ratio` (5 دقايق) → flip back. **قيس كام دقيقة الناس شافت errors** — ده سبب [46](46-canary-weighted-target-groups.md) |
| Drift | مع `managed_externally=false`: switch بالـ CLI ثم `terraform apply` | الـ apply بيرجّع 100/0 → الـ traffic رجع blue (rollback محدش طلبه) |
| مسح اللون الـ live | `green_enabled = false` وانت الأوزان 0/100 | الـ ASG green بيتمسح بس **الـ TG green لسه موجود في الـ listener بوزن 100** → 503 لكل الـ requests. القاعدة: رجّع 100% للون اللي هيفضل **قبل** ما تمسح التاني |

بعد أي تمرين، ده لازم يرجّع فاضي:

```bash
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[?contains(Name, `SRE_FAULT`)].Name'
```

## 9) الرجوع (Rollback)

```bash
# فوري (ثانية) — طول ما blue لسه شغال:
aws elbv2 modify-listener --listener-arn "$L" --default-actions \
  "[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[{\"TargetGroupArn\":\"$TGB\",\"Weight\":100},{\"TargetGroupArn\":\"$TGG\",\"Weight\":0}]}}]" >/dev/null
# لو كان scale_down_old=true: scale-up الأول، استنى healthy، وبعدين الـ flip
aws autoscaling update-auto-scaling-group --auto-scaling-group-name student-app-lab-blue --min-size 1 --desired-capacity 2
aws elbv2 wait target-in-service --target-group-arn "$TGB"
```

مع الـ Terraform way: رجّع `blue_weight = 100, green_weight = 0` + apply. وافتكر: الـ migrations مبترجعش.

## 10) المسح (Teardown) ⚠️

```bash
weights                                              # لازم blue=100 قبل ما تشيل green
# terraform.tfvars: green_enabled = false (وسيب listener_weights_managed_externally زي ما هو أو رجّعه false — recreate تاني)
terraform apply
```

امسح الـ rule `test-green` لو عملته، والـ LT/ASG بتوع الـ console. لو `scale_down_old` عمل `min=0`، أول `terraform apply` هيرجّع `min_size = 1` (والـ desired يطلع لـ 1 لوحده) — ده drift متوقع.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| لون تاني كامل (2 × `t3.micro` + IPv4 + gp3) | ~$0.03/ساعة ≈ $0.75/يوم طول ما الاتنين شغالين |
| `scale_down_old = true` | التوفير ده كله بعد كل release، مقابل rollback أبطأ (boot + healthy ~3–4 دقايق) |
| Alarm إضافي (`green-unhealthy-hosts`) | ~$0.10/شهر |
| الـ ALB | نفسه (مفيش LB تاني) |

## 12) أسئلة Interview

<details><summary>Blue/green بالأوزان على ALB مقابل DNS switch (Route 53)؟</summary>

الأوزان على الـ listener بتتطبّق على كل request جديد فوراً، ومن غير DNS caching (الـ clients والـ resolvers بيحتفظوا بالـ TTL وأحياناً أكتر). DNS switch (weighted records أو تغيير alias) مفيد لما الـ blue/green على مستوى ALB كامل أو region، بس الـ rollback بطيء وغير متوقع. جوه نفس الـ ALB: weights أحسن.

</details>

<details><summary>إيه مشكلة الـ drift هنا وإزاي اتحلت؟</summary>

اتنين بيكتبوا نفس الحقل (Terraform والـ CI) = آخر واحد يكسب: `terraform apply` عادي ممكن يرجّع الـ traffic للون القديم. الحل: ownership واضح — `ignore_changes = [default_action]` على listener منفصل (`*_external`) لما الـ CI يملك، أو الـ CI يكتب في tfvars ويعمل apply. ومينفعش `ignore_changes` بشرط، عشان كده resource-ين بـ `count`، وتغيير الـ flag = recreate.

</details>

<details><summary>تمن الـ blue/green ده إيه؟</summary>

ضعف الـ capacity وقت الـ deploy (وطول الـ bake، ولو سبت القديم للـ rollback)، داتابيز مشتركة لازم migrations متوافقة، config مشتركة، والـ capacity parity (الـ idle لازم يتسخّن لنفس حجم الـ live). في المقابل: test كامل قبل أي traffic، و rollback في ثانية من غير boot.

</details>

<details><summary>ليه الـ health checks مش كفاية تحكم على الـ green قبل الـ switch؟</summary>

الـ `/ready` بيقول "الـ process عايش وشايف الداتابيز"، مش "الصفحات صح". release بيرجّع 500 على `/login` بيعدّي منه. عشان كده: test route بـ header (§4.2)، smoke/synthetic على الـ idle، ثم bake بالـ alarms بعد الـ switch، أو canary تدريجي.

</details>

<details><summary>إمتى تعمل `scale_down_old`؟</summary>

لما الـ bake عدّى والثقة عالية (أو التكلفة أهم من سرعة الـ rollback). قبلها، القديم شغال = rollback ثانية. بعدها، الـ rollback = scale-up + boot + healthy (دقايق) — قريب من [44](44-rolling-instance-refresh.md). كمان خلّي بالك إن الـ `min_size` بتاع Terraform بيرجع في أول apply.

</details>

<details><summary>الـ long-lived connections (WebSocket/keep-alive) وقت الـ switch؟</summary>

الـ ALB بيوزّع **requests** (HTTP/1.1 keep-alive بيتوزّع لكل request)، فالـ requests الجديدة بتروح للون الجديد. الـ WebSockets القائمة بتفضل على الـ target القديم لحد ما تتقفل — لازم الـ client يعمل reconnect، والقديم ميتمسحش قبل ما الـ connections دي تخلص (أو تقبل قطعها).

</details>

## 13) Checklist

- [ ] عملت green من الـ console واختبرته بـ header rule قبل الـ switch
- [ ] عملت switch و rollback بالـ console والـ CLI والـ probe = 0 failures
- [ ] جرّبت الـ Terraform way (tfvars) وشفت الـ drift بعد CLI switch
- [ ] سلّمت الأوزان للـ CI (`listener_weights_managed_externally`) وحدّثت `ALB_LISTENER_ARN`
- [ ] شغّلت `bluegreen-switch` وجرّبت rollback أوتوماتيك من الـ bake
- [ ] رجّعت 100% لـ blue قبل `green_enabled = false`
