# 47 — Rolling deploy بـ Ansible (serial + drain)

> **الهدف في سطر:** تعمل rolling deploy **in-place** على الـ ASG fleet بـ [`rolling-asg.yml`](../../../infra/ansible/playbooks/rolling-asg.yml): migrations مرة، تعليق الـ ASG processes، ولكل instance (`serial: 1`): deregister + draining → `docker run --name student-app` بالـ image الجديدة → `/ready` محلي → register + انتظار `target-in-service` — وفي الآخر تحديث الـ IMAGE_URI و resume. وتفهم الـ failure semantics (`any_errors_fatal` / `max_fail_percentage`)، والـ credentials المطلوبة، وإمتى mutable deploy أحسن من immutable.
> **المستوى:** Advanced · **الوقت:** ~2–3 ساعات · **التكلفة التقريبية:** نفس [42](42-alb-asg-launch-template.md) (مفيش capacity زيادة)
> **بيعتمد على:** [42](42-alb-asg-launch-template.md) · [44](44-rolling-instance-refresh.md) · [33 — CD بـ Ansible](33-cd-ec2-ansible.md) · [93 — Ansible بالتفصيل](93-ansible-deep-dive.md) · **الملفات في الـ repo:** [`infra/ansible/playbooks/rolling-asg.yml`](../../../infra/ansible/playbooks/rolling-asg.yml) · [`infra/ansible/inventories/lab/aws_ec2.yml`](../../../infra/ansible/inventories/lab/aws_ec2.yml) · [`infra/ansible/inventories/lab/group_vars/all/main.yml`](../../../infra/ansible/inventories/lab/group_vars/all/main.yml) · [`infra/ansible/requirements.yml`](../../../infra/ansible/requirements.yml) · [`infra/ansible/README.md`](../../../infra/ansible/README.md) · [`modules/asg-app/user-data.sh.tftpl`](../../../infra/terraform/modules/asg-app/user-data.sh.tftpl)

## 1) الفكرة (Concepts)

[44](44-rolling-instance-refresh.md) بيبدّل الـ instances (immutable). هنا **نفس الـ instances** بتفضل، والـ container بس هو اللي بيتبدّل، و Ansible هو اللي بيتحكم في الترتيب والـ health gate. ده بالظبط اللي CodeDeploy in-place بيعمله ([37](37-aws-codedeploy-ec2.md)) — بس مكتوب كـ playbook تقدر تقراه.

| المصطلح | المعنى |
|---|---|
| `serial: 1` | Ansible بيشغّل الـ play على host واحد في المرة (batch). ممكن `2` أو `"25%"` |
| `any_errors_fatal: true` | أول task تفشل على أي host = الـ play كله يقف فوراً (مفيش host تاني يتلمس) |
| `max_fail_percentage: 0` | نسبة الـ hosts اللي ممكن تفشل في الـ batch قبل ما الـ play يقف (0 = ولا واحد) |
| `delegate_to: localhost` | الـ task (AWS API) تجري على جهازك بـ credentials بتاعتك، مش على الـ instance |
| Suspend processes | تجميد أجزاء من الـ ASG مؤقتاً (`HealthCheck`، `ReplaceUnhealthy`…) |
| Drain | deregister من الـ TG + انتظار `unused` (الـ in-flight خلصت أو الـ deregistration delay عدّى) |
| Health gate | الـ instance مترجعش الـ pool إلا لو الـ ALB نفسه شافها healthy |

## 2) المعمارية (Architecture)

```text
 laptop/WSL (credentials بتاعتك)                                   ASG student-app-lab-blue (+ green لو موجود)
 ┌─ Play 1: localhost ─────────────────────────────────────┐
 │ assert app_image (مش :latest) + hosts + TG ARNs          │
 │ rolling_asg_names ← tags aws:autoscaling:groupName       │
 │ suspend-processes HealthCheck ReplaceUnhealthy           │──► الـ ASG مش هيقتل instance متشالة من الـ TG
 │                   AZRebalance AlarmNotification          │    ولا يعمل scale/rebalance وانت بتعدّ
 │                   ScheduledActions                       │
 ├─ Play 2: role_app:&in_asg (run_once, any_errors_fatal) ──┤
 │ ECR login → docker run --rm --env-file app.env NEW       │──► php artisan migrate --force  (مرة، على أول host)
 ├─ Play 3: serial 1, any_errors_fatal, max_fail_percentage 0┤   لكل instance i (SSM connection):
 │ pre : docker_container_info student-app                  │    نفس الـ image؟ → end_host (idempotent)
 │       elb_target state=absent target_status=unused (90s) │──► draining (deregistration_delay 30s)
 │ main: ECR login → docker_image_pull → docker_container   │──► --name student-app -p 80:8080 --env-file app.env
 │       student-app (SIGQUIT/30, awslogs) → CURRENT_RELEASE │    DEPLOY_COLOR=<tag Color>
 │       uri http://127.0.0.1/ready until status=ready       │    (30 × 3s)
 │ post: elb_target state=present                            │
 │       aws elbv2 wait target-in-service (timeout 300)      │──► الـ ALB شافها healthy → الـ host اللي بعده
 ├─ Play 4: localhost ──────────────────────────────────────┤
 │ ssm_parameter {{ssm_prefix}}/deploy/<color>/IMAGE_URI=NEW │──► scale-out جاي يبوت نفس الـ release
 │ resume-processes (نفس الـ 5)                              │
 └──────────────────────────────────────────────────────────┘
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 40 شغال ([42](42-alb-asg-launch-template.md)) و image جديدة في ECR.
- [ ] WSL بـ Ansible + boto3 + `session-manager-plugin` + collections (`amazon.aws`، `community.aws`، `community.docker`) — [`infra/ansible/README.md` §1](../../../infra/ansible/README.md#1-install-wsl2-ubuntu). الـ repo جوه الـ WSL filesystem.
- [ ] S3 bucket تقدر **انت** تكتب فيه (الـ SSM connection بيعدّي ملفات الـ modules عن طريق presigned URLs): `terraform -chdir=infra/terraform/bootstrap output -raw ansible_ssm_bucket`.
- [ ] **Credentials بتاعتك** (مش الـ CI deploy role). الصلاحيات المطلوبة:

| Action | ليه | الـ CI deploy role عنده؟ |
|---|---|---|
| `ec2:DescribeInstances` (+ tags) | الـ dynamic inventory | ✅ (describe) |
| `autoscaling:SuspendProcesses` / `ResumeProcesses` | Play 1 و 4 | ❌ |
| `elasticloadbalancing:DeregisterTargets` / `RegisterTargets` / `DescribeTargetHealth` | الـ drain والـ register والـ wait | ❌ (عنده ModifyListener + Describe بس) |
| `ssm:StartSession` (+ `ssm:TerminateSession`) و S3 put/get على الـ bucket | الـ SSM connection | جزئياً |
| `ssm:PutParameter` على `/student-app/lab/deploy/*` | Play 4 | ✅ |

الـ deploy role مقصود يبقى ضيق ([80](80-iam-oidc-least-privilege.md)): الـ CI بيعمل immutable deploys (put-parameter + refresh)، والـ mutable deploy ده أداة operator.

## 4) الطريقة الأولى: AWS Console

مفيش "console way" لـ Ansible؛ بس تقدر تعمل نفس الخطوات بإيدك لـ instance واحدة عشان تحس بكل مرحلة:

1. **EC2 → Auto Scaling groups → `student-app-lab-blue` → Details → Advanced configurations → Edit** → **Suspended processes**: HealthCheck، ReplaceUnhealthy، AZRebalance، AlarmNotification، ScheduledActions → **Update**.
2. **Target groups → `student-app-lab-blue` → Targets** → اختار instance → **Deregister** → راقب `draining` → يختفي (~30s).
3. **Systems Manager → Session Manager** على نفس الـ instance:

```bash
sudo -i
NEW=<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/student-app:<NEW_SHA>
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${NEW%%/*}"
docker pull "$NEW"
docker rm -f student-app
docker run -d --name student-app --restart unless-stopped -p 80:8080 --env-file /opt/student-app/app.env \
  -e DEPLOY_COLOR=blue --stop-signal SIGQUIT --stop-timeout 30 \
  --log-driver awslogs --log-opt awslogs-group=/student-app/lab/app --log-opt awslogs-region=us-east-1 \
  --log-opt awslogs-stream="blue/$(cat /var/lib/cloud/data/instance-id)" "$NEW"
until curl -fsS http://127.0.0.1/ready | grep -q '"status":"ready"'; do sleep 3; done; echo ready
echo "$NEW" > /opt/student-app/CURRENT_RELEASE
```

4. **Target groups → Register targets** → نفس الـ instance → استنى `healthy`.
5. كرر لباقي الـ instances، وبعدين حدّث `/student-app/lab/deploy/blue/IMAGE_URI` و **resume** الـ processes.

> 💡 لاحظ إن الـ `docker rm -f` قبل الـ `docker run` = لحظة الـ instance فاضية — وده آمن **بس** لأنها متشالة من الـ TG. ده بالظبط سبب ترتيب الـ playbook.

## 5) الطريقة التانية: Infrastructure as Code (Ansible)

### 5.1 الـ inventory

```bash
cd infra/ansible
export AWS_REGION=us-east-1
ansible-inventory --graph                  # @in_asg, @color_blue, @scenario_40, @role_app …
ansible-inventory --host <INSTANCE_ID> | jq '{ansible_aws_ssm_instance_id, tags: {Color: .tags.Color, asg: .tags["aws:autoscaling:groupName"]}}'
BUCKET=$(terraform -chdir=../terraform/bootstrap output -raw ansible_ssm_bucket)
ansible 'role_app:&in_asg' -m ansible.builtin.ping -e ssm_bucket_name=$BUCKET
```

الـ groups من [`aws_ec2.yml`](../../../infra/ansible/inventories/lab/aws_ec2.yml): `in_asg` = عنده tag `aws:autoscaling:groupName` (الـ ASG بيحطه)، `standalone` = مفيهوش (host الـ 20). الـ default بتاع الـ playbook `role_app:&in_asg` → عمره ما يلمس الـ single host بالغلط، و `deploy.yml` عمره ما يلمس ASG member. الـ host name = **instance id** (اللي SSM محتاجه). الاتصال `amazon.aws.aws_ssm` (`deploy_connection: ssm` في group_vars) لأن الـ ASG members مفيهمش غير port 80 من الـ ALB.

### 5.2 الـ Variables

| Variable | من فين | المعنى |
|---|---|---|
| `app_image` | `-e` (إجباري) | image immutable (الـ assert بيرفض `:latest`) |
| `rolling_target_group_arns` | `-e "{\"rolling_target_group_arns\": $TG}"` من `terraform output -json target_group_arns` | dict `{blue, green}`؛ كل host بياخد TG لونه من tag `Color` |
| `rolling_target_group_arn` | بديل | TG واحد لكل الـ hosts |
| `target_hosts` | `-e` (اختياري) | default `role_app:&in_asg`؛ مثلاً `color_blue` |
| `rolling_run_migrations` | `-e` (default `true`) | `false` للـ rollback |
| `ssm_bucket_name` | `-e` | bucket الـ SSM transfers |
| `ssm_prefix`، `aws_region`، `app_dir`، `project`، `env_name` | [`group_vars/all/main.yml`](../../../infra/ansible/inventories/lab/group_vars/all/main.yml) | `/student-app/lab`، `us-east-1`، `/opt/student-app` |
| `rolling_drain_timeout` / `rolling_healthy_timeout` | play vars | 90 (الـ deregistration delay 30s) / 300 |
| `rolling_log_group` | play var | `/student-app/lab/app` (نفس الـ awslogs group بتاع stack 40) |

### 5.3 الـ playbook خطوة بخطوة

| Play / task | التفاصيل | لو فشلت |
|---|---|---|
| 1 · Validate inputs | `app_image` موجود ومش `:latest`، فيه hosts، فيه TG ARNs | يقف قبل أي تغيير |
| 1 · Find the ASGs | `rolling_asg_names` من tag `aws:autoscaling:groupName` لكل host (blue و green لو الاتنين في الـ inventory) | — |
| 1 · **Suspend** | `HealthCheck` + `ReplaceUnhealthy`: الـ instance المتشالة من الـ TG ممكن تتعلّم unhealthy وتتقتل في نص الـ deploy · `AZRebalance` / `AlarmNotification` (الـ target tracking) / `ScheduledActions`: محدش يزوّد أو يشيل instances وانت بتعدّهم | — |
| 2 · Migrate (`run_once`، `any_errors_fatal`) | `docker run --rm --env-file app.env NEW php artisan migrate --force` على أول host — **قبل** ما أي instance تخدم الجديد (expand/contract — [95](95-zero-downtime-db-migrations.md)). `changed_when` لو مفيش `Nothing to migrate` | الـ play كله يقف؛ مفيش instance اتلمست (بس الـ processes متعلقة — §9) |
| 3 · pre · Inspect + `end_host` | لو الـ container شغال بنفس الـ `Config.Image` → الـ host ده يتخطى خالص (re-run آمن بعد فشل) | — |
| 3 · pre · Drain | `community.aws.elb_target state=absent target_status=unused timeout 90` (delegate localhost) | الـ host بيفضل متشال |
| 3 · main · ECR login + pull | `docker_image_pull pull: not_present` | الـ host متشال من الـ TG، الـ play يقف (`any_errors_fatal`) |
| 3 · main · Replace container | `community.docker.docker_container` بنفس spec الـ user data: `-p 80:8080`، `env_file`، `DEPLOY_COLOR` من الـ tag، `SIGQUIT`/30، `unless-stopped`، awslogs stream `<color>/<id>` | نفس اللي فوق |
| 3 · main · `CURRENT_RELEASE` | `/opt/student-app/CURRENT_RELEASE` | — |
| 3 · main · Wait ready | `uri http://127.0.0.1/ready` لحد `status == ready` (30 × 3s) | الـ host الجديد مش ready → يفضل **بره** الـ TG ومحدش بيشوفه |
| 3 · post · Register | `elb_target state=present` | — |
| 3 · post · **Health gate** | `aws elbv2 wait target-in-service` (timeout 300): **الـ ALB نفسه** لازم يشوف `/ready` بيعدّي قبل ما الـ host اللي بعده يتشال | الـ play يقف والـ host اللي بعده سليم |
| 4 · Publish | `community.aws.ssm_parameter` → `/student-app/lab/deploy/<color>/IMAGE_URI = NEW` لكل لون اتلمس — **بعد** ما كل الـ hosts نجحوا (roll فاشل عمره ما يبقى اللي الـ scale-out بيبوته) | — |
| 4 · Resume | نفس الـ 5 processes | — |

### 5.4 `serial` و `any_errors_fatal` و `max_fail_percentage`

- `serial: 1` = أبداً مفيش أكتر من instance واحدة بره الـ pool → capacity **N−1** طول الـ roll (مع 2 instances = 50%!). مع fleet كبير: `serial: "25%"` أسرع بس capacity أقل.
- `any_errors_fatal: true` = أول failure بيوقف الـ play على **كل** الـ hosts فوراً — مفيش instance تانية بتتلمس، والفاشلة بتفضل بره الـ TG (عمرها ما خدمت الـ release البايظ).
- `max_fail_percentage: 0` = نفس المعنى لكل batch؛ متساب صريح لأنه الـ knob اللي بيتحكم مع `serial` أكبر (مثلاً `serial: "25%"` + `max_fail_percentage: 10`).

## 6) الـ Deploy

```bash
cd infra/ansible
TG=$(terraform -chdir=../terraform/stacks/40-ec2-alb-asg output -json target_group_arns)
BUCKET=$(terraform -chdir=../terraform/bootstrap output -raw ansible_ssm_bucket)
IMG=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com/student-app:<NEW_SHA>

# Terminal 1 (جهازك): القياس
bash ../../deploy/scripts/probe.sh "$(terraform -chdir=../terraform/stacks/40-ec2-alb-asg output -raw app_url)/ready" 0 0.2

# Terminal 2:
ansible-playbook playbooks/rolling-asg.yml -e app_image=$IMG -e "{\"rolling_target_group_arns\": $TG}" -e ssm_bucket_name=$BUCKET
# لون واحد بس:                          ... -e target_hosts=color_blue
# من غير migrations (rollback):         ... -e rolling_run_migrations=false
```

المفروض: الـ probe بيشوف القديم والجديد مخلوطين ثم الجديد بس، `failed : 0`، ومدة الـ roll ≈ (drain 30s + pull + start + healthy ~20s) لكل instance — **أسرع بكتير** من [44](44-rolling-instance-refresh.md) لأن مفيش boot.

## 7) التحقق (Verify)

```bash
ASG=student-app-lab-blue
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG --query 'AutoScalingGroups[0].SuspendedProcesses'   # لازم []
aws ssm get-parameter --name /student-app/lab/deploy/blue/IMAGE_URI --query Parameter.Value --output text
ansible 'role_app:&in_asg' -e ssm_bucket_name=$BUCKET -b -m ansible.builtin.command -a 'cat /opt/student-app/CURRENT_RELEASE'
aws elbv2 describe-target-health --target-group-arn "$(jq -r .blue <<<"$TG")" --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
# re-run = no-op (كل الـ hosts end_host):
ansible-playbook playbooks/rolling-asg.yml -e app_image=$IMG -e "{\"rolling_target_group_arns\": $TG}" -e ssm_bucket_name=$BUCKET -e rolling_run_migrations=false
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Image مش موجودة | `-e app_image=<repo>:doesnotexist -e rolling_run_migrations=false` | أول host: drained ثم `docker_image_pull` يفشل → الـ play يقف (`any_errors_fatal`). الـ host ده **بره الـ TG** (capacity N−1)، الباقي سليم، الـ IMAGE_URI **متغيّرش**، والـ processes **لسه suspended** (مقصود: "frozen for investigation"). الـ probe = 0 failures |
| Ctrl+C في نص الـ roll | اقطع بعد أول host | instance على الجديد، الباقي على القديم، الـ pointer على القديم، processes suspended → mixed fleet. افتكر: لو الـ ASG بدّل instance دلوقتي هتبوت **القديم** |
| من غير suspend (تفكير، متجرّبوش على حاجة مهمة) | — | زي ما تعليق الـ playbook بيقول: الـ `HealthCheck` ممكن يعلّم الـ instance الـ drained كـ unhealthy و `ReplaceUnhealthy` يقتلها في نص الـ deploy (أو أول ما تعمل resume)، والـ target tracking (`AlarmNotification`) ممكن يعمل scale-in لـ instance انت شغال عليها أو scale-out بيبوت الـ pointer القديم وانت بتعدّ الـ hosts |
| Release بيرجّع 500 | (مش هيتكشف هنا) | الـ gate = `/ready` بس → الـ roll هيكمّل لكل الـ fleet. الـ playbook مفيهوش metric gate — قارن بـ [46](46-canary-weighted-target-groups.md) |

## 9) الرجوع (Rollback)

```bash
# 1) لو الـ play وقف: resume الأول (أو هيتعمل في آخر الـ run الجاي)
for ASG in student-app-lab-blue student-app-lab-green; do
  aws autoscaling resume-processes --auto-scaling-group-name $ASG 2>/dev/null && echo "resumed $ASG"
done
# 2) roll بالإصدار السابق (من الـ pointer history — Play 4 بيحدّثه بس لما الـ roll ينجح)
PREV=$(aws ssm get-parameter --name /student-app/lab/deploy/blue/IMAGE_URI --query Parameter.Value --output text)
ansible-playbook playbooks/rolling-asg.yml -e app_image=$PREV -e "{\"rolling_target_group_arns\": $TG}" \
  -e ssm_bucket_name=$BUCKET -e rolling_run_migrations=false
```

(`resume-processes` من غير `--scaling-processes` = resume لكل الـ processes المتعلقة.)

⚠️ **فخ الـ idempotency:** الـ host اللي فشل في الـ pull لسه شغّال الـ container **القديم** (= `PREV`) بس متشال من الـ TG. في الـ rollback بـ `PREV`، الـ pre-task "Skip instances that already run this release" هيعمله `end_host` **قبل** الـ register → هيفضل بره الـ TG. سجّله بإيدك:

```bash
aws elbv2 describe-target-health --target-group-arn "$(jq -r .blue <<<"$TG")" --query 'TargetHealthDescriptions[].Target.Id'
aws elbv2 register-targets --target-group-arn "$(jq -r .blue <<<"$TG")" --targets Id=<INSTANCE_ID>
```

أو terminate الـ instance دي وخلّي الـ ASG يبوت واحدة جديدة من الـ pointer.

## 10) المسح (Teardown) ⚠️

مفيش resources جديدة. اتأكد: `SuspendedProcesses` فاضية للونين، الـ IMAGE_URI = اللي على الـ instances فعلاً، وكل الـ targets `healthy`. الـ stack نفسه: [42 §10](42-alb-asg-launch-template.md).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (تقريبي، راجع صفحة الأسعار) |
|---|---|
| Capacity زيادة | **صفر** (in-place) — بس الـ capacity بتنزل لـ N−1 أثناء الـ roll |
| S3 (ملفات الـ SSM transfer) | سنتات |
| SSM Session Manager | مجاني |

## 12) أسئلة Interview

<details><summary>Mutable (in-place) ولا immutable deploys؟</summary>

Immutable (refresh/blue-green): مفيش drift، الـ rollback = البيئة السابقة، والـ instance دايماً من وصفة معروفة؛ التمن boot أبطأ و capacity زيادة. Mutable (Ansible/CodeDeploy in-place): أسرع (مفيش boot)، مفيش capacity زيادة، ومناسب لـ hotfix سريع، AMIs تقيلة، hosts فيها state/licenses، أو on-prem؛ التمن drift محتمل، وإن الـ instance اللي اتعملها deploy ممكن تختلف عن اللي هتبوت بكرة (عشان كده Play 4 بيحدّث الـ pointer). كتير من الفرق: immutable كـ default و in-place كأداة طوارئ.

</details>

<details><summary>ليه تعلّق الـ ASG processes وقت الـ deploy؟</summary>

الـ ASG مش عارف إنك بتعمل deploy: `ReplaceUnhealthy`/`HealthCheck` ممكن يقتل instance انت شيلتها أو بتعيد تشغيل الـ container بتاعها، `AZRebalance` ممكن يبدّل instances، و `AlarmNotification` (scaling) ممكن يضيف instance بتبوت release تاني أو يشيل واحدة انت شغال عليها. التمن: مفيش autoscaling ولا self-healing طول الـ roll، فخلّيه قصير، و resume دايماً (حتى بعد فشل — أو اعرف إنها متعلقة عن قصد).

</details>

<details><summary>`serial` و `max_fail_percentage` و `any_errors_fatal` بيفرقوا في إيه؟</summary>

`serial` بيحدد حجم الـ batch (capacity اللي بره الـ pool). `max_fail_percentage` بيقول كام % من الـ batch ممكن تفشل قبل ما الـ play يقف. `any_errors_fatal` بيوقف الـ play كله عند أول failure على أي host (وبيكسب لو اتحدد). في deploy: `serial` صغير + `any_errors_fatal` = blast radius = instance واحدة بره الـ pool، والإصدار البايظ مبيخدمش ولا request.

</details>

<details><summary>ليه الـ health gate بـ `aws elbv2 wait target-in-service` مش `/ready` المحلي بس؟</summary>

`/ready` المحلي بيقول الـ container ready، بس الـ ALB ممكن يكون شايف حاجة تانية (SG، port، path، الـ health check config). الـ wait بيتأكد إن الـ load balancer نفسه بيبعت traffic قبل ما تشيل الـ host اللي بعده — وإلا ممكن تشيل كل الـ fleet واحدة ورا التانية وكلهم "ready" محلياً و unhealthy في الـ TG.

</details>

<details><summary>ليه الـ playbook بيشتغل بـ credentials بتاعتك مش الـ CI role؟</summary>

محتاج `RegisterTargets/DeregisterTargets` و `Suspend/ResumeProcesses` و SSM sessions — صلاحيات بتغيّر شكل الـ fleet مباشرة. الـ CI deploy role متصمم least-privilege للـ immutable flow (put-parameter + refresh + modify-listener). لو عايز تشغّله من CI: role منفصل بـ approval (environment protection) وبـ conditions على الـ tags/ASG names.

</details>

<details><summary>إيه الفرق بين ده و CodeDeploy in-place؟</summary>

نفس الـ flow (BlockTraffic → ApplicationStop → Install → Start → ValidateService → AllowTraffic) و `minimum healthy hosts`. CodeDeploy: managed، agent على الـ instance، revisions في S3، rollback أوتوماتيك على alarms، ومتكامل مع الـ ASG lifecycle hooks (instance جديدة بتاخد آخر revision). Ansible: شفاف ومرن ومن غير agent، بس إنت اللي بتكتب الـ orchestration والـ rollback ([37](37-aws-codedeploy-ec2.md)).

</details>

## 13) Checklist

- [ ] عملت drain → replace → register لـ instance واحدة بإيدك من الـ console و Session Manager
- [ ] شغّلت `rolling-asg.yml` والـ probe = 0 failures، وقرأت كل play
- [ ] اتأكدت إن الـ re-run no-op (`end_host`)
- [ ] جرّبت image مش موجودة: host واحد بره الـ TG، الـ pointer متغيّرش، الـ processes متعلقة
- [ ] عملت resume و rollback بالإصدار السابق
- [ ] أقدر أشرح إمتى أختار mutable ولا immutable
