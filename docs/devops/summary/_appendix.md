# ملاحق

> مراجع سريعة للطباعة. التفاصيل في [96](scenarios/96-comparison-matrices.md) (المقارنات)، [97](scenarios/97-cost-and-teardown.md) (التكلفة والمسح)، و [99](scenarios/99-cheatsheets-and-troubleshooting.md) (الأوامر والأعطال).

## أ) مصفوفة استراتيجيات الـ deployment

| الاستراتيجية | Downtime | الـ rollback | تكلفة زيادة | الـ gate | Single EC2 | ASG | ECS | EKS |
|---|---|---|---|---|---|---|---|---|
| Recreate | ثواني–دقايق | redeploy (بطيء) | صفر | healthcheck | `docker-compose.prod.yml` | CodeDeploy AllAtOnce ≈ | — | `Recreate` (manifests) |
| Rolling | صفر | rolling تاني / circuit breaker | surge صغير | readiness / ELB health | `rolling.sh` | instance refresh · Ansible serial · CodeDeploy OneAtATime | `ROLLING` + breaker | RollingUpdate (helm) |
| Blue/Green | صفر | **ثواني** | 2× وقت الـ deploy | smoke قبل الـ switch + bake | `bluegreen.sh` | `bluegreen-switch` (ASG-ين) | CodeDeploy / native `BLUE_GREEN` | selector / Argo `blueGreen` |
| Canary | صفر | ثواني (weight → 0) | slot/pod أو لون كامل | **metric gate** (5xx ratio) | `canary.sh` (exit 2) | `canary-weights` + alarm | CodeDeploy Canary / native `CANARY` | Argo Rollouts + analysis |
| Linear | صفر | زي canary | زي B/G على ECS | alarms بين الخطوات | `STEPS` متساوية ≈ | `canary_steps` ≈ | CodeDeploy Linear / native `LINEAR` | steps ≈ |
| A/B | صفر | `ab-test.sh stop` | نسختين لأيام | business metrics | `ab-test.sh` | — | — | — |
| Shadow | صفر | `shadow.sh stop` | 2× + load على الـ DB | مقارنة metrics | `shadow.sh` (GET/HEAD) | — | — | — |
| Feature flags | صفر | toggle من غير deploy | ~صفر | product metrics | مفهوم + Pennant (تمرين) | ← | ← | ← |

- أي zero-downtime = إصدارين على نفس الـ schema ← **expand/contract** ([95](scenarios/95-zero-downtime-db-migrations.md)). الـ migrations مبترجعش مع أي rollback.
- الـ health checks مبتشوفش `SRE_FAULT_ERROR_RATE` ← محتاج metric gate أو deployment alarms.
- الـ gates: `canary.sh` (`MAX_ERROR_RATE` 0.01، `MIN_REQUESTS` 10، fail closed) · ASG (`student-app-lab-alb-5xx-ratio`، خطوة 300s) · ECS (`use_deployment_alarms`) · Argo (`maxErrorRate` 0.05، `failureLimit` 1، `isNaN` = fail open).

## ب) EC2 مقابل ECS مقابل EKS

| | EC2 (single / ASG) | ECS Fargate | EKS |
|---|---|---|---|
| الـ ops burden | الأعلى (OS، Docker، AMIs) | الأقل (مفيش servers) | عالي (upgrades، add-ons، nodes) |
| أقل تكلفة idle (المعمل) | stack 20 ≈ $0.03/h · 40 ≈ $0.08/h | ≈ $0.11/h | ≈ $0.23/h (control plane $0.10/h) |
| الـ scaling | ASG target tracking (CPU + requests) — دقايق | 2–6 tasks (CPU 50% + requests) — أقل من دقيقة | HPA 2–6 (CPU 70%) + Karpenter |
| الـ deploy | refresh، weighted TGs، CodeDeploy، Ansible | rolling + breaker، native B/G/linear/canary، CodeDeploy | RollingUpdate، Argo Rollouts، Argo CD |
| الـ secrets | `render-env-from-ssm.sh` → `app.env` | `secrets[].valueFrom` (SSM ARN) | ESO → `student-app-secrets` |
| الـ debug | Session Manager | ECS Exec | `kubectl` |
| اختاره لما | حمل صغير / تحكم في الـ host / legacy | **الافتراضي** لفريق صغير/متوسط على AWS | فرق كتير + ecosystem الـ K8s + platform team |

## ج) التكلفة وترتيب المسح

| Stack | السيناريوهات | ≈ $/ساعة | ≈ $/يوم | أهم بند / مصيدة |
|---|---|---|---|---|
| bootstrap | 02، 30، 80 | — | < $0.50/شهر | ECR (30 image) + state versions |
| 20-ec2-single | 20–27، 31–33 | 0.03 | ~0.70 | EIP + EBS بيتحاسبوا والـ instance stopped |
| 35-codebuild | 35 | 0 idle | — | ~$0.05/push |
| 36-codepipeline | 36، 37، 58 | 0 idle | — | ~$0.05/release |
| 40-ec2-alb-asg | 40–49 | 0.08 | ~2 | ALB + RDS؛ NAT +0.045/h، Redis +0.013/h |
| 50-ecs-fargate | 50–58 | 0.11 | ~2.70 | Fargate + 4 IPv4 + RDS؛ Container Insights |
| 60-eks | 60–6A | 0.23 | ~5.50 | control plane $0.10/h؛ ALB الـ LBC +0.03/h |

**أكبر المصايد:** NAT (~$32/شهر لكل واحد) · EKS control plane · ALB قاعد idle · RDS (والـ stop بيصحى بعد 7 أيام) · public IPv4 ($0.005/h لكل واحد) · CloudWatch Logs من غير retention · ECR storage · Container Insights · Fargate بعد load test · manual snapshots وAMIs بعد الـ destroy.

```text
0) اللي برّه Terraform: kubectl delete ingress --all -A · LoadBalancer svcs · Karpenter NodePools
   FIS templates · WAF · RDS manual/PITR/cross-region snapshots · AMIs+snapshots · Console resources · eksctl
1) 36-codepipeline   (لازم قبل 50)
2) 35-codebuild
3) الـ app stack الوحيد: 20 | 40 | 50 | 60   (نفس SSM paths ← واحد بس لكل env)
4) فحص البواقي (tagging API + EIP/NAT/ALB/RDS/EBS/snapshots/log groups)
5) bootstrap — بس لو خلصت نهائياً: state local ← apply بـ ecr_force_delete + state_bucket_force_destroy ← destroy
```

## د) Cheat sheet في صفحة

```bash
# --- Local / CI
export APP_KEY=base64:$(openssl rand -base64 32); docker compose up -d --build --wait
docker compose run --rm app php artisan migrate --force
gh workflow run lab-integration.yml --ref devops-lab && gh run watch        # كمان: k8s-integration.yml
# --- Single host (deploy/ec2/lb)
SKIP_PULL=true bash bin/init.sh <IMAGE>
bash ../../scripts/with-probe.sh -- bash bin/bluegreen.sh <IMAGE>            # KEEP_OLD, DRAIN_SECONDS, SLOT_ENV
STEPS="10 25 50 100" STEP_SECONDS=30 MAX_ERROR_RATE=0.01 bash bin/canary.sh <IMAGE>
bash bin/rollback.sh && bash bin/status.sh
bash deploy/scripts/probe.sh http://<HOST>/ready 120 0.2                     # MAX_FAILURES=0 → exit 1 لو فشل
# --- Terraform
terraform init -backend-config=../../backend.hcl && terraform plan -out=tfplan && terraform apply tfplan
terraform plan -refresh-only                                                 # drift
terraform force-unlock <LOCK_ID>                                             # آخر حل
terraform destroy
gh workflow run terraform.yml --ref master -f stack=<NN-name> -f action=plan  # apply | destroy
# --- AWS
aws ssm start-session --target <INSTANCE_ID>
aws ssm get-parameter-history --name /student-app/lab/deploy/blue/IMAGE_URI --query 'Parameters[-3:].Value'
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].deployments[].[rolloutState,taskDefinition]'
aws elbv2 describe-target-health --target-group-arn <TG_ARN> --query 'TargetHealthDescriptions[].TargetHealth'
aws autoscaling describe-instance-refreshes --auto-scaling-group-name student-app-lab-blue --query 'InstanceRefreshes[0].Status'
aws logs tail /ecs/student-app-lab/app --follow --since 10m
# --- Deploy workflows
gh workflow run deploy-ecs.yml -f image_tag=<SHA7> -f strategy=rolling           # native | codedeploy
gh workflow run deploy-asg.yml -f image_tag=<SHA7> -f strategy=instance-refresh  # bluegreen-switch | canary-weights
gh workflow run deploy-eks.yml -f image_tag=<SHA7> -f mode=helm                  # rollouts | gitops-bump
# --- Kubernetes
aws eks update-kubeconfig --name student-app-lab
kubectl -n student-app get pods,ingress,rollout,analysisrun,externalsecret
kubectl -n student-app get events --sort-by=.lastTimestamp | tail -20
helm -n student-app history student-app && helm -n student-app rollback student-app
kubectl argo rollouts get rollout student-app -n student-app --watch          # promote | abort | retry rollout | undo
# --- k6 (exit 99 = SLO threshold اتكسر)
k6 run -e BASE_URL=http://<HOST> -e LOADTEST_USERS=20 -e VUS=10 -e DURATION=5m -e P95_MS=300 loadtest/k6/load.js
```

## هـ) أشهر 10 أعطال

| العَرَض | السبب | الحل |
|---|---|---|
| Targets unhealthy في الـ TG | بورت غلط (stack 40 = **80**، 50/EKS = **8080**)، `/ready` 503، SG | `describe-target-health` (Reason) + `curl /ready \| jq .reason` |
| `/ready` = 503 | `database unreachable` / `SRE_FAULT_UNHEALTHY` / unready flag | صلّح الـ DB أو الـ fault، أو `POST /sre-lab/ready` |
| 419 أو mixed content ورا ALB | sessions مش مشتركة / `APP_KEY` مختلف / `X-Forwarded-Proto` | `SESSION_DRIVER=database`، `APP_KEY` واحد من SSM، `trustProxies` + `APP_URL=https://` |
| `canary.sh` exit 2 | pre-traffic checks / مفيش traffic (أو `/metrics` 403/404) / error rate | ولّد traffic على `/login`، راجع `METRICS_ENABLED`/`METRICS_TOKEN`، أو صلّح الـ release |
| `rollback.sh`: nothing to roll back to | `BROKEN` marker — الـ deploy الفاشل مخدش traffic أصلاً | طبيعي؛ deploy إصدار سليم |
| ECS `rolloutState = FAILED` | circuit breaker (boot fail، image، secrets) | `describe-tasks` → `stoppedReason` |
| `CannotPullContainerError` / `ResourceInitializationError` | tag مش في ECR، مفيش طريق لـ ECR/SSM، execution role، arch | `ecr describe-images`، public IP/NAT، الـ role، multi-arch |
| Rollout `Degraded` | analysis فشل، أو مفيش series (PodMonitor/`METRICS_TOKEN`) | `get analysisrun`، صلّح ثم `retry rollout` أو `helm rollback` |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | `sub` مش مطابق (environment بدل branch، PR، branch جديد) أو role var غلط | قارن الـ `sub` بـ `github-oidc.tf`؛ deployment branches على الـ environment |
| `Error acquiring the state lock` | apply شغال أو run اتلغى وساب `.tflock` | اتأكد مفيش run، وبعدين `terraform force-unlock <ID>` |
