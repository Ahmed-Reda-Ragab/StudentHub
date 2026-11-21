# 96 — جداول المقارنة (الاستراتيجيات، المنصات، أدوات الـ CI)

> **الهدف في سطر:** تجمع كل اللي عملته في المعمل في جداول تقدر تبص عليها وتقرر في دقيقة: أنهي deployment strategy، على أنهي منصة، بأنهي أداة CI/IaC/secrets/observability، وإيه التمن والمخاطرة. وكل خانة بتشاور على الملف أو الـ workflow الحقيقي في الـ repo.
> **المستوى:** Advanced · **الوقت:** ~2 ساعة قراءة + مراجعة · **التكلفة التقريبية:** مجاني (مفيش موارد)
> **بيعتمد على:** [22–26](22-recreate-and-measuring-downtime.md) · [44–47](44-rolling-instance-refresh.md) · [53–55](53-ecs-rolling-circuit-breaker.md) · [66–69](66-k8s-rolling-recreate.md) · [95 — expand/contract](95-zero-downtime-db-migrations.md) · **الملفات في الـ repo:** [`deploy/ec2/lb/bin/`](../../../deploy/ec2/lb/bin) · [`.github/workflows/`](../../../.github/workflows) · [`infra/terraform/stacks/`](../../../infra/terraform/stacks) · [`k8s/helm/student-app/values.yaml`](../../../k8s/helm/student-app/values.yaml) · [`infra/ansible/playbooks/`](../../../infra/ansible/playbooks)

## 1) الفكرة (Concepts)

الـ interviewer نادراً بيسأل "يعني إيه canary". بيسأل: **"عندك X، هتختار إيه وليه، وإيه اللي ممكن يبوظ؟"**. الجداول دي معمولة عشان تجاوب على السؤال ده بأرقام وأمثلة من شغلك انت.

| المحور | بنقيسه إزاي في المعمل |
|---|---|
| Downtime | `deploy/scripts/probe.sh` (أو `with-probe.sh` بـ `MAX_FAILURES=0`) أثناء الـ deploy ([22](22-recreate-and-measuring-downtime.md)) |
| سرعة الـ rollback | الوقت من القرار لحد ما 100% من الـ traffic على الإصدار السليم |
| التكلفة الزيادة | capacity زيادة وقت الـ deploy (slots / instances / tasks / pods) |
| التعقيد | عدد الأجزاء المتحركة: LB rules، metrics، gate، state |
| المخاطرة (blast radius) | كام مستخدم بيشوف الإصدار الجديد قبل ما نعرف إنه سليم |
| قيد الـ DB migrations | الإصدارين بيشتغلوا على نفس الـ schema قد إيه؟ ([95](95-zero-downtime-db-migrations.md)) |
| الكشف (detection) | مين بيقول "وقّف": health check، smoke، metric gate، alarm، إنسان |

> 💡 **قاعدة واحدة تحكم كل الجداول:** أي استراتيجية "zero-downtime" معناها إن **الإصدارين بيخدموا في نفس الوقت**، يعني الـ schema لازم يكون متوافق مع الاتنين. والـ migrations **مبترجعش** مع أي rollback (`rollback.sh` نفسه بيطبع warning بكده).

## 2) (a) استراتيجيات الـ deployment

### 2.1 التمن والمخاطرة

| الاستراتيجية | Downtime | سرعة الـ rollback | التكلفة الزيادة | التعقيد | المخاطرة (blast radius) |
|---|---|---|---|---|---|
| **Recreate** | أيوه: ثواني (container) لدقايق (instance) | بطيئة: redeploy للقديم + downtime تاني | صفر | ⭐ | 100% من المستخدمين مرة واحدة |
| **Rolling** | صفر لو الـ readiness والـ drain مظبوطين | متوسطة: rolling تاني بالقديم (دقايق)؛ ECS circuit breaker أوتوماتيك | surge صغير (`maxSurge 1` · `MaxHealthy 150%` · `maximumPercent 200%`) | ⭐⭐ | بيكبر تدريجياً، والإصدارين مع بعض |
| **Blue/Green** | صفر | **ثواني** (switch تاني) طول ما القديم شغال | 2× وقت الـ deploy (أو لحد ما تقفل القديم) | ⭐⭐⭐ | 100% مرة واحدة بعد الـ switch، بس الجديد اتختبر قبلها |
| **Canary** | صفر | ثواني (weight → 0) أثناء التجربة؛ بعد الـ promote = deploy جديد | slot/pod زيادة (single host، Argo)؛ لون كامل (ASG weighted، ECS) | ⭐⭐⭐⭐ (metrics + gate) | صغير: 10% في أول خطوة |
| **Linear** | صفر | زي الـ canary | زي الـ B/G على ECS (الـ green بيقوم كامل من الأول) | ⭐⭐⭐ | بيكبر بخطوات متساوية |
| **A/B** | صفر | ثواني (`ab-test.sh stop`) | نسختين شغالين أيام/أسابيع | ⭐⭐⭐ + تحليل إحصائي | نسبة مستخدمين ثابتة (sticky) |
| **Shadow** | صفر (ردّ الـ shadow بيترمي) | مش محتاج: `shadow.sh stop` | 2× compute للـ shadow + load مضاعف على الـ dependencies | ⭐⭐⭐⭐ (side effects) | صفر على المستخدم… إلا لو الـ writes اتعملها mirror |
| **Feature flags** | صفر | **ثواني من غير deploy** (toggle) | ~صفر infra؛ التكلفة في الكود (flag debt) | ⭐⭐ في الأول وبيكبر مع عدد الـ flags | انت بتحدده (user / نسبة) |

### 2.2 الـ migrations والكشف وفين في الـ repo

| الاستراتيجية | قيد الـ DB migrations | الكشف (مين بيقول "وقّف") | فين في الـ repo |
|---|---|---|---|
| Recreate | أي migration "بتعدّي" لأن فيه downtime أصلاً، بس الـ rollback للكود القديم محتاج schema متوافق | healthcheck `/up` بعد `up -d` + الـ probe بيقيس الـ downtime | [`docker-compose.prod.yml`](../../../docker-compose.prod.yml) + [`deploy-pull-image.sh`](../../../deploy/ec2/deploy-pull-image.sh) ([`deploy-ec2-ssm.yml`](../../../.github/workflows/deploy-ec2-ssm.yml))، [`deploy-build-on-server.sh`](../../../deploy/ec2/deploy-build-on-server.sh) ([`deploy-ec2-ssh-build.yml`](../../../.github/workflows/deploy-ec2-ssh-build.yml))، `playbooks/deploy.yml`، K8s `Recreate` في plain manifests ([66](66-k8s-rolling-recreate.md)) |
| Rolling | الإصدارين بيخدموا مع بعض → **expand/contract إجباري** | readiness `/ready` / ELB health / circuit breaker — **مش بيشوف** الـ error rate إلا لو فيه alarms | [`rolling.sh`](../../../deploy/ec2/lb/bin/rolling.sh) · [`deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml) `instance-refresh` · [`rolling-asg.yml`](../../../infra/ansible/playbooks/rolling-asg.yml) · ECS `ROLLING` ([`deploy-ecs.yml`](../../../.github/workflows/deploy-ecs.yml) `strategy=rolling`) · [`deploy-eks.yml`](../../../.github/workflows/deploy-eks.yml) `mode=helm` |
| Blue/Green | الكود القديم بيشتغل على الـ schema الجديد (بين الـ migrate والـ switch + طول الـ rollback window) | ready + smoke على الـ idle **قبل** الـ switch، و bake على الـ alarms بعده (`bake_seconds`)، أو Argo pre-promotion analysis | [`bluegreen.sh`](../../../deploy/ec2/lb/bin/bluegreen.sh) ([`deploy-ec2-bluegreen.yml`](../../../.github/workflows/deploy-ec2-bluegreen.yml)) · `deploy-asg.yml` `bluegreen-switch` · ECS `CODE_DEPLOY` / native `BLUE_GREEN` · [`values-bluegreen.yaml`](../../../k8s/helm/student-app/values-bluegreen.yaml) |
| Canary | الإصدارين مع بعض دقايق لساعات → expand/contract | **metric gate**: 5xx ratio للـ canary بس (`/metrics` للـ slot، CloudWatch alarm، Prometheus AnalysisTemplate) | [`canary.sh`](../../../deploy/ec2/lb/bin/canary.sh) ([`deploy-ec2-canary.yml`](../../../.github/workflows/deploy-ec2-canary.yml)) · `deploy-asg.yml` `canary-weights` · ECS `ECSCanary10Percent5Minutes` / native `CANARY` · `deploy-eks.yml` `mode=rollouts` |
| Linear | نفس الـ canary | alarms بين الخطوات (CodeDeploy / ECS deployment alarms) | ECS: `CodeDeployDefault.ECSLinear10PercentEvery1Minutes` أو native `LINEAR` (step 25% / 2m). الباقي: خطوات متساوية في `STEPS` / `canary_steps` / `rollout.canary.steps` |
| A/B | نسختين لأيام → compat صارم، والـ schema لازم يخدم الـ variant-ين | business metrics + statistical significance (مش error rate) | [`ab-test.sh`](../../../deploy/ec2/lb/bin/ab-test.sh) بس (`split_clients` + cookie `ab_variant` + header `X-Variant`) |
| Shadow | الـ writes بتتكرر → `shadow.sh` بيعمل mirror لـ GET/HEAD بس؛ في الحقيقة: بيئة معزولة بداتابيز منفصلة | مقارنة metrics/logs/latency بتاعة الـ shadow بالـ live | [`shadow.sh`](../../../deploy/ec2/lb/bin/shadow.sh) بس (nginx `mirror`) |
| Feature flags | الـ schema لازم يخدم الحالتين (on/off)؛ الـ flag مش بيرجّع migration | product metrics + kill switch | مفهوم + Laravel Pennant **تمرين (مش متثبت)** + AWS AppConfig اختياري ([26](26-ab-testing-shadow-feature-flags.md)). `SRE_LAB_ENABLED` مثال على env kill switch (محتاج recreate بسبب الـ config cache) |

### 2.3 الـ gates الحقيقية جنب بعض

نفس الفكرة ("الـ canary سليم؟") متطبّقة 4 مرات في الـ repo بأرقام مختلفة. اعرف الفرق، لأنه سؤال interview ممتاز:

| الـ gate | بيقيس إيه | الـ threshold | لو مفيش traffic؟ | الملف |
|---|---|---|---|---|
| `canary.sh` (single host) | `student_app_http_requests_total` من `/metrics` بتاع الـ slot (من غير `sre-lab.*` و `health.ready` و `up`) قبل/بعد كل خطوة | `MAX_ERROR_RATE=0.01`، `MIN_REQUESTS=10`، `STEP_SECONDS=30` | **fail closed**: يستنى خطوة كمان، وبعدين abort (exit 2) | [`canary.sh`](../../../deploy/ec2/lb/bin/canary.sh)، `slot_counters` في [`lib.sh`](../../../deploy/ec2/lb/bin/lib.sh) |
| `deploy-asg.yml` `canary-weights` | CloudWatch alarm على الـ ALB كله | `student-app-lab-alb-5xx-ratio`، `step_seconds` 300 (الـ alarms بـ 5-minute windows) | الـ alarm بيفضل OK → الخطوة بتعدّي | [`deploy-asg.yml`](../../../.github/workflows/deploy-asg.yml) |
| ECS deployment alarms | CloudWatch alarms مربوطة بالـ deployment | `use_deployment_alarms = true` في stack 50 | نفس الـ ASG | [`modules/ecs-fargate/service.tf`](../../../infra/terraform/modules/ecs-fargate/service.tf) |
| Argo Rollouts AnalysisTemplate | 5xx ratio للـ canary pods بس (`pod=~".+-<hash>-.+"`) على app routes | `maxErrorRate` 0.05، `interval` 30s، `failureLimit` 1 | **fail open**: `isNaN(result[0])` بيعدّي → promoted. (من غير scraping خالص = مفيش series = Error → abort) | [`analysistemplate.yaml`](../../../k8s/helm/student-app/templates/analysistemplate.yaml) |

> ⚠️ الـ health checks **مبتشوفش** `SRE_FAULT_ERROR_RATE` (الـ `/ready` بيفضل 200). عشان كده rolling و B/G من غير metric gate بيعدّوا release بيرجّع 500 على 30% من الصفحات ([23 §8](23-bluegreen-single-host.md)).

## 3) (b) المنصة × الاستراتيجية

### 3.1 الـ grid

| | Recreate | Rolling | Blue/Green | Canary | Linear | A/B | Shadow | Flags |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **Single EC2** (stack 20 + `deploy/ec2/lb`) | ✅ | ✅ | ✅ | ✅ | ≈ | ✅ | ✅ | 📝 |
| **ASG** (stack 40) | ≈ | ✅ | ✅ | ✅ | ≈ | — | — | 📝 |
| **ECS Fargate** (stack 50) | — | ✅ | ✅ | ✅ | ✅ | — | — | 📝 |
| **EKS** (stack 60) | ✅ | ✅ | ✅ | ✅ | ≈ | — | — | 📝 |

✅ متطبّق في الـ repo · ≈ ممكن بإعداد (خطوات متساوية / config) · — مش متطبّق · 📝 مفهوم وتمرين على مستوى التطبيق (مستقل عن المنصة)

### 3.2 Single EC2 — `deploy/ec2/lb/bin/*.sh` (nginx قدام slotين)

| الاستراتيجية | الآلية | الـ gate | الـ rollback | # |
|---|---|---|---|---|
| Recreate | migrate (`run --rm`) → `docker compose -f docker-compose.prod.yml up -d` | healthcheck `/up` | `deploy-pull-image.sh rollback` (بيقرا `PREVIOUS_RELEASE`) | [22](22-recreate-and-measuring-downtime.md)، [31](31-cd-ec2-ssh-build-on-server.md)–[33](33-cd-ec2-ansible.md) |
| Rolling | `render_pool` → slot واحد `down` → drain `DRAIN_SECONDS` (3) → `start_slot` → يرجع للـ pool | `start_slot` (migrate → ready → smoke)؛ لو فشل الـ peer ياخد 100% والسكريبت يقف | `rollback.sh` (`MODE=rolling` → `rolling.sh` بـ `PREVIOUS_IMAGE`) | [25](25-rolling-single-host.md) |
| Blue/Green | `start_slot IDLE` → `render_single IDLE` → `nginx -t` + `nginx -s reload` | ready + smoke (`/up` `/ready` `/login`) على `127.0.0.1:<port>` قبل الـ switch | `rollback.sh`: فوري لو `KEEP_OLD=true`؛ بيرفض لو اللون التاني `BROKEN` | [23](23-bluegreen-single-host.md) |
| Canary | `render_weighted` بـ `STEPS` (`10 25 50 100`) كل `STEP_SECONDS` | `slot_counters`: 5xx/total > `MAX_ERROR_RATE` أو traffic أقل من `MIN_REQUESTS` → abort، `BROKEN=<canary>`، exit **2** | أوتوماتيك (abort) أو `rollback.sh` (`MODE=canary` → 100% على `ACTIVE`) | [24](24-canary-single-host.md) |
| A/B | `split_clients "${remote_addr}${http_user_agent}"` + cookie `ab_variant` + header `X-Variant` | إنسان + business metrics | `ab-test.sh stop` | [26](26-ab-testing-shadow-feature-flags.md) |
| Shadow | `mirror /__shadow` لـ GET/HEAD، `proxy_read_timeout 3s` | مقارنة `/metrics` الـ slotين | `shadow.sh stop` | [26](26-ab-testing-shadow-feature-flags.md) |

نفس السكريبتات بتتشغّل من 3 أماكن: shell على السيرفر، SSM Run Command ([`deploy-ec2-ssm.yml`](../../../.github/workflows/deploy-ec2-ssm.yml) كـ engine لـ bluegreen/canary/[`release-promote.yml`](../../../.github/workflows/release-promote.yml))، و Ansible (`playbooks/{bluegreen,canary,rollback}.yml`)، ومن غير AWS خالص على GitHub runner ([`lab-integration.yml`](../../../.github/workflows/lab-integration.yml)).

### 3.3 ASG — stack 40 (ALB + TGs `blue`/`green`)

| الطريقة | الآلية | الـ gate | الـ rollback | # |
|---|---|---|---|---|
| Instance refresh | `put-parameter /student-app/<env>/deploy/<color>/IMAGE_URI` → `start-instance-refresh` (`MinHealthy 100` / `MaxHealthy 150` / `InstanceWarmup 120`) | ELB health `/ready` + `AlarmSpecification` | الـ workflow بيرجّع الـ IMAGE_URI القديم + refresh تاني. `AutoRollback=false` لأن الـ release في SSM مش في الـ launch template | [44](44-rolling-instance-refresh.md) |
| Weighted TGs — B/G | الـ ASG الـ idle تقوم بالـ image الجديدة → TG healthy → `modify-listener` 100% في call واحد | bake `bake_seconds` (300) على الـ alarms | flip back (ثواني). `scale_down_old` افتراضياً `false` | [45](45-bluegreen-two-asgs.md) |
| Weighted TGs — Canary | نفس التجهيز، وبعدين weights `canary_steps` (`10 25 50 100`) | `CANARY_ALARM_NAME` (`student-app-lab-alb-5xx-ratio`) بين الخطوات | weights → 100% على الـ stable | [46](46-canary-weighted-target-groups.md) |
| CodeDeploy (Server) | agent + [`appspec.yml`](../../../deploy/codedeploy/ec2/appspec.yml) + hooks؛ `IN_PLACE` بـ `OneAtATime` (default) / `HalfAtATime` / `AllAtOnce` | `validate-service.sh`: `/ready` = 200 **و** `"version":"<sha>"` | auto rollback على `DEPLOYMENT_FAILURE` (+ `DEPLOYMENT_STOP_ON_ALARM` لو فيه alarms). `BLUE_GREEN` بيعمل copy للـ ASG برّه Terraform | [37](37-aws-codedeploy-ec2.md) |
| Ansible serial | `rolling-asg.yml`: `serial: 1`، `any_errors_fatal`، `max_fail_percentage: 0` → drain من الـ TG → deploy → health-gate → register | الـ health-gate بتاع الـ playbook | الـ instance اللي فشلت بتفضل برّه الـ TG والـ ASG processes **suspended** (مقصود) → `aws autoscaling resume-processes` | [47](47-ansible-rolling-deploy.md) |

> ⚠️ لو الـ CI غيّر الـ weights بـ `modify-listener`، انسخها في tfvars (`blue_weight`/`green_weight`) أو خلي `listener_weights_managed_externally = true`، وإلا أول `terraform apply` هيرجّعها (drift — [91](91-terraform-import-and-drift.md)).

### 3.4 ECS Fargate — stack 50

| الطريقة | الإعداد | الـ gate | الـ rollback | # |
|---|---|---|---|---|
| Rolling + circuit breaker | `deployment_strategy = "ROLLING"`، min 100% / max 200% | circuit breaker (threshold ≈ نص الـ desired، أقل حاجة 3) + `use_deployment_alarms` | أوتوماتيك لآخر deployment `COMPLETED` | [53](53-ecs-rolling-circuit-breaker.md) |
| CodeDeploy B/G / Canary / Linear | `deployment_controller = "CODE_DEPLOY"` + `codedeploy_deployment_config_name` (`ECSAllAtOnce` default، `ECSCanary10Percent5Minutes`، `ECSLinear10PercentEvery1Minutes`…)، [`appspec.yaml`](../../../deploy/ecs/appspec.yaml) | CloudWatch alarms على الـ deployment group | CodeDeploy بيرجّع الـ listener للـ original task set | [54](54-ecs-codedeploy-bluegreen-canary.md) |
| ECS-native B/G / Linear / Canary | `deployment_strategy = "BLUE_GREEN" \| "LINEAR" \| "CANARY"`، `bake_time_in_minutes` (5)، canary 10%/5m، linear 25%/2m، test traffic بـ header `X-Lab-Target: green` | deployment alarms + bake time | الـ weights ترجع للـ blue اللي لسه شغال | [55](55-ecs-native-bluegreen-linear-canary.md) |

الـ deploy: `deploy-ecs.yml` (`strategy=rolling|native|codedeploy`) أو stack 36 (`deploy_mode=ecs|codedeploy-ecs|codebuild`). التحويل بين ROLLING والـ traffic-shifting، أو ECS ⇄ CODE_DEPLOY على service موجود = `terraform apply -replace=module.ecs.aws_ecs_service.app`.

### 3.5 EKS — stack 60 + `k8s/`

| الطريقة | الإعداد | الـ gate | الـ rollback | # |
|---|---|---|---|---|
| RollingUpdate | `maxSurge 1` / `maxUnavailable 0`، readiness `/ready` + ALB readiness gate، `preStop` 10s، PDB | `helm upgrade --install --wait --rollback-on-failure --timeout 10m` | تلقائي من Helm لو فشل، أو `helm rollback` | [66](66-k8s-rolling-recreate.md) |
| Blue/Green | يدوي: Deployment-ين + Service selector switch. أو Argo `blueGreen` (`values-bluegreen.yaml`): preview Service، `autoPromotionEnabled: false`، `scaleDownDelaySeconds: 30` | pre-promotion analysis (web: الـ preview `/ready` لازم `ready`) | `kubectl argo rollouts undo` / رجّع الـ selector | [67](67-k8s-bluegreen.md) |
| Canary | Argo Rollouts: `setWeight` 10 → 25 → 50 (pauses 2m/2m/5m) → 100، ALB `trafficRouting` على EKS | AnalysisTemplate (Prometheus) | abort أوتوماتيك → `Degraded` → stable 100%؛ يدوي `kubectl argo rollouts abort` | [68](68-k8s-canary-argo-rollouts.md) |
| GitOps (delivery مش strategy) | `deploy-eks.yml mode=gitops-bump` → PR يغيّر `image.tag` في `values-eks.yaml` → Argo CD sync (ExternalSecret wave -1 → migrate Job wave 0 → Rollout wave 1) | نفس الـ canary analysis | `git revert` للـ bump commit | [69](69-gitops-argocd.md) |

## 4) (c) EC2 مقابل ECS مقابل EKS

| | EC2 (single / ASG) | ECS Fargate | EKS |
|---|---|---|---|
| الـ ops burden | الأعلى: OS patching، Docker، agent، user-data، AMIs (Packer) | الأقل: مفيش servers؛ task definition + service | عالي: cluster upgrades كل ~سنة، add-ons (LBC، ESO، Argo، Prometheus)، nodes، RBAC |
| أقل تكلفة idle في المعمل (us-east-1، تقريبي) | stack 20 ≈ $0.03/h · stack 40 ≈ $0.08/h | stack 50 ≈ $0.11/h | stack 60 ≈ $0.23/h (الـ control plane لوحده $0.10/h) |
| الـ scaling | ASG target tracking (CPU + requests per target)، Spot اختياري — دقايق (boot instance) | service autoscaling 2–6 tasks (CPU 50% + requests per target)، FARGATE_SPOT — أقل من دقيقة | HPA 2–6 pods (CPU 70%) + Karpenter للـ nodes — ثواني للـ pods |
| مميزات الـ deploy | كل حاجة بإيدك: instance refresh، weighted TGs، CodeDeploy، Ansible | rolling + circuit breaker، native B/G/linear/canary، CodeDeploy — كلها managed | RollingUpdate، Argo Rollouts (analysis)، GitOps، Helm hooks |
| الـ secrets | `render-env-from-ssm.sh` → `app.env` (chmod 600) | `secrets[].valueFrom` (SSM ARN) — execution role | ESO → Secret `student-app-secrets` (Pod Identity) |
| الـ debug | Session Manager على الـ host | ECS Exec (`deploy/ecs/ecs-exec.sh`) | `kubectl exec/logs/describe/events` |
| الـ portability | عالية (Docker في أي حتة) | AWS بس (task definition) | عالية (K8s API)، بس الـ add-ons الخاصة بـ AWS لأ |
| إمتى تختاره | تطبيق واحد/اتنين، فريق صغير، ميزانية ضيقة، أو legacy محتاج host | الافتراضي لفريق صغير/متوسط على AWS عايز containers من غير cluster | منصة لفرق كتير، أو محتاج ecosystem الـ K8s (GitOps، operators، multi-cloud)، وفيه ناس تشيل الـ platform |

> 💡 **إجابة الـ interview المختصرة:** "ECS Fargate افتراضياً. EC2 لو الحمل صغير أو محتاج تحكم في الـ host. EKS لما يبقى عندي platform team وأسباب حقيقية للـ ecosystem — مش عشان الـ CV."

## 5) (d) GitHub Actions مقابل CodeBuild/CodePipeline مقابل Argo CD

| | GitHub Actions | CodeBuild + CodePipeline | Argo CD |
|---|---|---|---|
| النموذج | push: الـ runner بيكلّم AWS | push من جوه AWS | **pull**: controller جوه الـ cluster بيطابق git |
| الـ identity | OIDC → `student-app-gha-*` (مفيش keys) | service roles جوه الحساب | الـ controller بصلاحيات الـ cluster؛ الـ CI مبيلمسش الـ cluster |
| في الـ repo | `ci.yml`، `deploy-*.yml`، `terraform.yml`، `release-promote.yml`، `lab-integration.yml`… | stack 35 (`student-app-ci`، `-image`، `-gha-runner`) + stack 36 (Source → Build → [Approve] → Deploy) | [`k8s/argocd/`](../../../k8s/argocd) + `deploy-eks.yml mode=gitops-bump` |
| الـ approvals | GitHub environments (`lab`، `production`) + required reviewers | Manual approval stage (`require_approval`) | PR review على الـ bump |
| الـ concurrency | `concurrency` + `cancel-in-progress: false` | `execution_mode = QUEUED` | sync واحد في المرة لكل app |
| الـ rollback | re-run بالـ tag القديم / `rollback.sh` / `helm rollback` | re-run execution قديم أو CodeDeploy rollback | `git revert` |
| الـ drift | مش بيشوفه | مش بيشوفه | `selfHeal: true` بيرجّع أي تعديل يدوي |
| التكلفة | minutes (مجاني لـ public repos، حصة للـ private) | CodeBuild ≈ $0.005/دقيقة، V2 pipeline ≈ $0.002/action-minute، مفيش idle | مجاني (بس شغّال على الـ cluster) |
| إمتى | الافتراضي لو الكود على GitHub | compliance بيطلب كل حاجة جوه AWS، أو private networking/VPC | K8s + فرق متعددة + audit trail في git |

التفاصيل والتجربة جنب بعض: [58](58-ecs-github-actions-vs-codepipeline.md)، [35](35-aws-codebuild.md)، [36](36-aws-codepipeline.md)، [69](69-gitops-argocd.md).

## 6) (e) Terraform مقابل Ansible مقابل Packer مقابل user-data مقابل Helm

| الأداة | بتعمل إيه | الـ state | إمتى بتشتغل | في الـ repo |
|---|---|---|---|---|
| Terraform | provisioning لموارد AWS (declarative) | S3 + lockfile | `plan`/`apply` | `bootstrap/` + 12 module + 6 stacks |
| Ansible | configuration + deploy على hosts موجودة (procedural، idempotent) | مفيش (الـ host نفسه هو الـ state) | كل deploy / كل تغيير config | `infra/ansible` (7 roles، 7 playbooks) |
| Packer | بيبني AMI جاهز (golden image) | مفيش — الناتج AMI | قبل الـ deploy، مرة لكل تحديث base | [`infra/packer`](../../../infra/packer) ([43](43-golden-ami-packer.md)) |
| user-data | bootstrap عند أول boot للـ instance | مفيش | مرة عند الـ launch | [`deploy/ec2/user-data.sh`](../../../deploy/ec2/user-data.sh)، `modules/asg-app/user-data.sh.tftpl` |
| Helm | packaging + release management على K8s (templates + values + hooks + history) | release secrets في الـ cluster | `helm upgrade --install` | [`k8s/helm/student-app`](../../../k8s/helm/student-app) |

**مين بيملك إيه (أهم قرار في المعمل):**

| الحاجة | المالك | الآلية |
|---|---|---|
| الـ infra (VPC، ALB، RDS، roles) | Terraform | stacks |
| الـ image الشغالة | **CI** | `ignore_changes` على `IMAGE_URI` (ASG) و `task_definition` (ECS)؛ `image.tag` في git (GitOps) |
| الـ secrets | SSM (Terraform بيعمل القيمة الأولى) | `render-env-from-ssm.sh` / ECS `secrets` / ESO |
| الـ listener weights أثناء deploy | CI أو CodeDeploy | `listener_weights_managed_externally` / `weights_managed_externally` |
| الـ OS config | Ansible أو Packer (immutable) | roles / AMI |

## 7) (f) الـ Secrets: SSM مقابل Secrets Manager مقابل ESO

| | SSM Parameter Store | Secrets Manager | External Secrets Operator |
|---|---|---|---|
| النوع | store (String / SecureString بـ KMS) | store متخصص في الـ secrets | **مش store** — sync من store لـ K8s Secret |
| Rotation | يدوي (انت بتعمل الـ process) | مدمج (Lambda أو managed، زي RDS master password) | بيعمل refresh كل `refreshInterval` (1h) أو force-sync |
| Versions | history للـ parameter | `AWSCURRENT` / `AWSPREVIOUS` | — |
| التكلفة | Standard مجاني (لحد 4KB) | ~$0.40/secret/شهر + API calls | مجاني (pods في الـ cluster) |
| في الـ repo | **مصدر الحقيقة**: `/student-app/<env>/app/*` | بديل للـ RDS password (`use_secrets_manager`) — [81](81-secrets-management.md) | `ClusterSecretStore` (provider `ParameterStore`) + ExternalSecret `student-app-secrets` — [64](64-eks-external-secrets.md) |
| المستهلكين | EC2 (`render-env-from-ssm.sh`)، ECS (`valueFrom`)، ESO | ECS / ESO / SDK | pods (envFrom) |
| إمتى | config + secrets عادية، تكلفة صفر | لما الـ rotation الأوتوماتيك أو cross-account sharing مطلوب | على K8s بدل `kubectl create secret` يدوي أو secrets في git |

## 8) (g) الـ Observability: CloudWatch مقابل Prometheus/Grafana

| | CloudWatch | Prometheus + Grafana (+ Loki) |
|---|---|---|
| الـ metrics | ALB/ECS/RDS/ASG جاهزة من غير agent | app metrics من `/metrics` (`student_app_http_requests_total`…) |
| دقة الـ SLI | **تقريبية**: الـ ALB مالوش path dimension، فمش قادر يستثني `/sre-lab/*` | **دقيقة**: per route/status، والـ drill SLI منفصل (`drill="true"`) |
| الـ alerting | alarms + composite (`student-app-lab-slo-fast-burn`) → SNS | recording rules + multi-window burn-rate → Alertmanager (receiver "drill" منفصل عن الـ pager) |
| الـ logs | CloudWatch Logs + Logs Insights | Loki + Alloy (LogQL) |
| التشغيل | managed | انت بتشغّله (compose / kube-prometheus-stack) |
| التكلفة | pay-per-use (alarms، logs ingestion، Container Insights) | compute + storage بتوعك |
| في الـ repo | `modules/observability`، [`observability/cloudwatch`](../../../observability/cloudwatch) | [`observability/prometheus`](../../../observability/prometheus)، [`observability/compose`](../../../observability/compose)، [`observability/k8s`](../../../observability/k8s) |
| بيتجرّب في | stacks 40/50/60 | local / CI / EC2 / EKS — وهو اللي الـ Argo canary analysis معتمد عليه |

> ⚠️ drill بـ `/sre-lab/error` على الـ ALB **هيشغّل** `slo-fast-burn` في CloudWatch ويبعت email؛ الفصل بين الـ drill والـ budget الحقيقي موجود في Prometheus بس ([CONVENTIONS §5](../CONVENTIONS.md)).

## 9) دليل الاختيار (Decision guide)

```text
عندك release جديد
 │
 ├─ فيه DB migration مش backward compatible؟ ──► اقسمه expand/contract الأول (95). مفيش استراتيجية بتنقذك.
 │
 ├─ مسموح بدقيقة downtime؟ (internal tool، maintenance window) ──► Recreate. أبسط وأرخص.
 │
 ├─ عندك metrics per-release موثوقة + traffic كفاية؟
 │     ├─ أيوه ──► Canary (أو Linear لو عايز خطوات ثابتة ومحسوبة) + auto-abort
 │     └─ لأ  ──► Blue/Green بـ smoke قوي + bake على alarms (الـ rollback ثواني)
 │
 ├─ capacity مضاعفة غالية/مش متاحة؟ ──► Rolling (maxSurge صغير) + circuit breaker / alarms
 │
 ├─ السؤال "المستخدمين هيحبوا الـ feature؟" مش "الإصدار سليم؟" ──► A/B أو feature flag
 │
 └─ تغيير خطير في الأداء (rewrite، dependency جديدة) ومحتاج traffic حقيقي من غير مخاطرة ──► Shadow (reads بس)
```

| لو… | اختار | وتجنّب |
|---|---|---|
| فريق صغير على AWS، تطبيق واحد | ECS Fargate + rolling/circuit breaker، وبعدين native canary | EKS |
| ميزانية المعمل/الـ startup صفر تقريباً | EC2 واحد + `deploy/ec2/lb` (B/G + canary على nginx) | NAT، EKS |
| متطلبات compliance: كل حاجة جوه AWS | CodePipeline + CodeDeploy | runners برّه بـ keys |
| فرق كتير على K8s | Argo CD + Argo Rollouts + ESO | `kubectl apply` من الـ CI |
| الـ secrets محتاجة rotation أوتوماتيك | Secrets Manager (و ESO بيقرا منه) | SSM لوحده |
| SLO دقيق per route | Prometheus/Grafana | CloudWatch ALB metrics لوحدها |
| immutable infra على EC2 | Packer AMI + instance refresh | Ansible على instances شغالة (mutable) |

## 10) التحقق (Verify)

اختبر نفسك من غير ما تبص على الجداول:

- [ ] تقدر تقول الـ gate بتاع كل platform بيقيس إيه، والـ threshold بتاعه، وبيعمل إيه لو مفيش traffic.
- [ ] تقدر تفسّر ليه `AutoRollback=false` في `deploy-asg.yml`.
- [ ] تقدر ترسم الـ B/G على 4 منصات وتقول الـ "switch" فيهم إيه (nginx reload، `modify-listener`، CodeDeploy/ECS listener rule، Service selector/Argo).
- [ ] تقدر تحسب تكلفة يوم معمل لكل stack من [97](97-cost-and-teardown.md).

## 11) أسئلة Interview

<details><summary>Canary ولا Blue/Green؟ امتى كل واحد؟</summary>

Canary لما عندك metrics per-release موثوقة وtraffic كفاية تحكم بيه في دقايق: الـ blast radius صغير والقرار أوتوماتيك. Blue/Green لما الحكم مش ممكن بنسبة صغيرة (traffic قليل، أو التغيير لازم يتختبر كامل) وعايز rollback فوري: بتختبر الـ idle قبل أي traffic وبتحوّل مرة واحدة. في المعمل: `bluegreen.sh` عدّى release بـ 30% errors لأن الـ smoke request واحد، و `canary.sh` بيوقفه في أول خطوة.

</details>

<details><summary>ليه الـ health checks مش كفاية كـ gate؟</summary>

لأنها بتقيس "الـ process عايش والـ DB بترد" مش "المستخدم بياخد ردود صح". `SRE_FAULT_ERROR_RATE=0.5` بيخلّي نص الصفحات 500 و `/ready` بيفضل 200. الـ circuit breaker والـ ELB health والـ readiness كلهم هيعدّوه. محتاج metric gate (5xx ratio للإصدار الجديد) أو deployment alarms.

</details>

<details><summary>الـ canary gate بتاعك لو مفيش traffic بيعمل إيه؟ وده صح؟</summary>

في `canary.sh`: fail closed — لو أقل من `MIN_REQUESTS` يستنى خطوة كمان وبعدين abort (exit 2). في الـ Argo AnalysisTemplate: `isNaN(result[0])` بيعدّي، يعني من غير traffic الإصدار بيتعمله promote (fail open)، ومن غير scraping خالص مفيش series فبيعمل abort. الصح يعتمد على الـ context: في production بتحط حد أدنى للـ requests أو synthetic traffic، لأن gate أعمى بيعمل promote هو أخطر حاجة.

</details>

<details><summary>إزاي تعمل rollback لـ migration؟</summary>

مبتعملش، في الغالب. بتصمّم الـ migrations إنها backward compatible (expand/contract): add column nullable → الكود يكتب في الاتنين → backfill → الكود يقرا الجديد → drop القديم بعد ما الـ rollback window يخلص. الـ down migrations في production خطر (داتا بتضيع). كل الـ rollback scripts في الـ repo بتطبع "migrations are NOT rolled back".

</details>

<details><summary>ECS: CodeDeploy blue/green ولا ECS-native blue/green؟</summary>

الـ native (2025) أبسط: نفس الـ ECS controller، مفيش appspec ولا CodeDeploy app، الأرقام بتاعتك مباشرة (`BLUE_GREEN` / `LINEAR` / `CANARY`)، والتحويل بين الـ strategies in-place. CodeDeploy عنده configs جاهزة و lifecycle hooks وتكامل مع CodePipeline `CodeDeployToECS`، بس بيملك الـ listener والـ task sets، والتحويل من/لـ ECS controller محتاج `-replace` للـ service. للمشروع الجديد: native، إلا لو الـ pipeline مبني على CodeDeploy.

</details>

<details><summary>EC2 ولا ECS ولا EKS لـ startup فيها 3 developers؟</summary>

ECS Fargate: مفيش servers ولا cluster upgrades، deploy features كاملة (circuit breaker، native canary)، والتكلفة في المعمل ≈ $0.11/h مقابل ≈ $0.23/h لـ EKS (الـ control plane لوحده $0.10/h). EKS بيستاهل لما يبقى فيه فرق كتير ومحتاجين الـ ecosystem وفيه حد يشيل الـ platform. EC2 لو الحمل صغير جداً أو محتاج تحكم في الـ host.

</details>

<details><summary>ليه الـ CI هو اللي بيملك الـ image مش Terraform؟</summary>

لأن الـ image بتتغير مع كل commit والـ infra لأ. لو Terraform بيملكها، كل deploy = `terraform apply` بصلاحيات admin، وأي apply لتغيير infra صغير ممكن يرجّع image قديمة. في الـ repo: `ignore_changes = [value]` على `/student-app/<env>/deploy/<color>/IMAGE_URI` و `ignore_changes = [task_definition]` على الـ ECS service. Terraform بيعمل القيمة الأولى بس.

</details>

<details><summary>Argo CD (pull) ولا GitHub Actions (push) للـ deploy على K8s؟</summary>

Pull: الـ cluster credentials مبتخرجش برّه الـ cluster، git هو الـ audit trail، والـ drift بيترجع أوتوماتيك (`selfHeal`)، والـ rollback = `git revert`. Push أبسط ومناسب لـ cluster واحد وفريق صغير، بس الـ CI محتاج صلاحيات على الـ cluster. الـ repo فيه الاتنين: `deploy-eks.yml mode=helm|rollouts` (push) و `mode=gitops-bump` (pull). متشغّلش الاتنين على نفس الـ environment.

</details>

<details><summary>SSM Parameter Store ولا Secrets Manager؟</summary>

SSM SecureString مجاني (Standard) وكفاية لـ config + secrets عادية، والـ layout `/student-app/<env>/app/<KEY>` بيتحول env مباشرة على EC2/ECS/EKS. Secrets Manager (~$0.40/secret/شهر) لما محتاج rotation أوتوماتيك (RDS master password)، versions `AWSCURRENT/AWSPREVIOUS`، أو cross-account. ESO مش بديل لهم؛ ده sync لـ K8s Secret.

</details>

<details><summary>CloudWatch ولا Prometheus للـ SLOs؟</summary>

الاتنين. CloudWatch مجاني التشغيل ومتاح على كل منصة من غير agent، بس الـ SLI من ALB metrics تقريبي (مفيش path dimension، الـ drills بتحرق الـ budget). Prometheus بيدّي SLI دقيق per route وdrill منفصل وburn-rate rules متختبرة بـ `promtool test rules`، بس انت بتشغّله. على EKS، الـ canary analysis نفسه معتمد على Prometheus.

</details>

## 12) Checklist

- [ ] قريت كل جدول وربطت كل خانة بسيناريو عملته
- [ ] شغّلت على الأقل B/G و canary على منصتين مختلفتين وقارنت الـ gate
- [ ] تقدر تجاوب على الـ decision guide من غير ما تبص
- [ ] حطيت أهم جدولين في الـ portfolio ([98](98-portfolio-and-interview.md))
