## K — الختام (96–99)

### 96 — جداول المقارنة (الاستراتيجيات، المنصات، أدوات الـ CI)
**الهدف:** تختار الـ strategy والمنصة والأداة في دقيقة: downtime، سرعة الـ rollback، التكلفة، قيد الـ migrations، الـ gate، وفين متطبّقة في الـ repo.
**أهم الأوامر:**
```bash
bash deploy/ec2/lb/bin/canary.sh "$REPO:<SHA7>"                                  # single host: metric gate (exit 2)
gh workflow run deploy-asg.yml -f strategy=canary-weights -f image_tag=<SHA7>      # ASG: weighted TGs + alarm
gh workflow run deploy-ecs.yml -f strategy=native -f image_tag=<SHA7>              # ECS-native B/G / linear / canary
gh workflow run deploy-ecs.yml -f strategy=codedeploy -f image_tag=<SHA7>          # ECS + CodeDeploy
gh workflow run deploy-eks.yml -f mode=rollouts -f image_tag=<SHA7>                # EKS: Argo Rollouts + analysis
gh workflow run deploy-eks.yml -f mode=gitops-bump -f image_tag=<SHA7>             # Argo CD (pull)
gh workflow run lab-integration.yml --ref devops-lab                               # كل استراتيجيات الـ single host من غير AWS
```
**التحقق:** تقدر تقول لكل gate بيقيس إيه، والـ threshold بتاعه، وبيعمل إيه لو مفيش traffic (`canary.sh` fail closed، Argo `isNaN` fail open) · **Gotchas:** • الـ health checks مبتشوفش `SRE_FAULT_ERROR_RATE` — rolling و B/G من غير metric gate بيعدّوه • أي zero-downtime = إصدارين على نفس الـ schema → expand/contract • `AutoRollback=false` في الـ instance refresh لأن الـ release في SSM مش في الـ launch template · **التكلفة:** مجاني (مراجعة)

### 97 — التكلفة والمسح
**الهدف:** تعرف تكلفة كل stack بالساعة وأكبر المصايد، وتمسح بالترتيب الصح وتتأكد إن مفيش بواقي — apply الصبح، destroy بالليل.
**أهم الأوامر:**
```bash
kubectl delete ingress --all -A                                                   # قبل destroy الـ 60
terraform -chdir=infra/terraform/stacks/36-codepipeline destroy                    # قبل 50 دايماً
terraform -chdir=infra/terraform/stacks/50-ecs-fargate destroy
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=student-app --query 'ResourceTagMappingList[].ResourceARN' --output text
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp'
aws logs describe-log-groups --query 'logGroups[?retentionInDays==null].logGroupName'
aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier'
aws ce get-cost-and-usage --time-period Start=$(date -d yesterday +%F),End=$(date +%F) --granularity DAILY --metrics UnblendedCost --query 'ResultsByTime[0].Total'
```
**التحقق:** الـ tagging API مفيهوش غير `Scenario=02` (bootstrap)، ومفيش EIP/NAT/ALB/RDS/EKS، والفاتورة بكرة ≈ سنتات · **Gotchas:** • ترتيب: برّه Terraform ← 36 ← 35 ← app stack واحد (20/40/50/60) ← فحص ← bootstrap آخر حاجة • stop ≠ destroy (EBS و IPv4 بيتحاسبوا، و RDS بيصحى لوحده بعد 7 أيام) • manual snapshots و log groups من غير retention بيعيشوا بعد الـ destroy · **التكلفة:** stack 20 ≈ $0.03/h · 40 ≈ $0.08/h · 50 ≈ $0.11/h · 60 ≈ $0.23/h · NAT +$0.045/h

### 98 — الـ Portfolio وأسئلة الـ Interview
**الهدف:** README hero + رسم معمارية + 3 demo stories + ADRs + CV bullets بأرقام + 50 سؤال Senior DevOps/SRE مربوطين بالسيناريوهات.
**أهم الأوامر:**
```bash
gh workflow run lab-integration.yml --ref devops-lab && gh run watch               # demo 1 مجاناً (canary abort)
gh workflow run deploy-ec2-canary.yml -f image_tag=<SHA7> -f slot_env=SRE_FAULT_ERROR_RATE=0.5 -f expect_abort=true
cd deploy/ec2/lb && SLOT_ENV="SRE_FAULT_ERROR_RATE=0.1" SKIP_PULL=true bash bin/bluegreen.sh student-app:v2   # demo 2
bash bin/rollback.sh && bash bin/status.sh
terraform plan -generate-config-out=generated.tf                                   # demo 3 (import blocks)
terraform plan -detailed-exitcode; echo "exit=$?"
```
**التحقق:** كل demo ليها GIF/فيديو + لينك run أخضر، و 3 ADRs بالقالب، وجاوبت الـ 50 سؤال بصوت عالي بمثال من الـ repo · **Gotchas:** • متكتبش في الـ CV رقم مقستهوش • "zero-downtime" مش "zero errors": الـ canary ليه blast radius (10% × خطوة) • 10% errors بياخد ~43 دقيقة للـ fast-burn tier — عشان كده الـ canary · **التكلفة:** مجاني على GitHub Actions؛ demo على AWS = تكلفة الـ stack لساعة

### 99 — Cheat sheets و Troubleshooting
**الهدف:** أوامر كل أداة في صفحة، وسكريبتات المعمل بالـ env vars بتاعتها، وجدول عَرَض ← سبب ← حل لأشهر أعطال المعمل.
**أهم الأوامر:**
```bash
curl -s http://<HOST>/ready | jq '{status,reason,version,color}'
bash deploy/ec2/lb/bin/status.sh
aws ecs describe-services --cluster student-app-lab --services student-app-lab-app --query 'services[0].deployments[].[status,rolloutState]'
aws ecs describe-tasks --cluster student-app-lab --tasks <TASK_ARN> --query 'tasks[0].stoppedReason'
aws elbv2 describe-target-health --target-group-arn <TG_ARN> --query 'TargetHealthDescriptions[].TargetHealth'
kubectl -n student-app describe externalsecret student-app-secrets
kubectl argo rollouts get rollout student-app -n student-app && kubectl -n student-app get analysisrun
terraform force-unlock <LOCK_ID>
```
**التحقق:** حلّيت 5 أعطال على الأقل من الجدول بنفسك وعارف تقرا `reason` بتاع `/ready` و `stoppedReason` و `TargetHealth.Reason` · **Gotchas:** • بورت الـ TG: stack 40 = 80 (host)، stack 50/EKS = 8080 (ip) • `canary.sh` exit 2 = pre-traffic checks أو مفيش traffic (`/metrics` أعمى) أو error rate • OIDC: job فيه `environment` → الـ `sub` = `environment:<name>` مش branch · **التكلفة:** مجاني
