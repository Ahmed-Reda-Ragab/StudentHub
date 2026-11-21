# E — EC2 على نطاق أكبر (40–49): كروت الملخص

> كارت لكل سيناريو. التفاصيل في [`../scenarios/`](../scenarios/40-vpc-from-scratch.md)، والـ stack في [`infra/terraform/stacks/40-ec2-alb-asg`](../../../infra/terraform/stacks/40-ec2-alb-asg/README.md). الأسعار تقريبية (us-east-1) — راجع صفحة الأسعار.

### 40 — VPC من الصفر
**الهدف:** VPC `10.20.0.0/16` بـ public/private `/20` على 2 AZ، IGW، route tables، S3 gateway endpoint، default SG مقفول — بالـ wizard ثم `modules/network` — وتفهم قرار "من غير NAT".
**أهم الأوامر:**
```bash
cd infra/terraform/stacks/40-ec2-alb-asg && terraform init -backend-config=../../backend.hcl
echo 'cidrsubnet("10.20.0.0/16", 4, 8)' | terraform console        # 10.20.128.0/20 (أول private)
terraform plan -target=module.network -out=net.tfplan && terraform apply net.tfplan
aws ec2 describe-route-tables --filters Name=tag:Project,Values=student-app --query 'RouteTables[].Routes[].[DestinationCidrBlock,GatewayId||NatGatewayId]' --output text
terraform plan -target=module.network -var private_instances=true    # شوف NAT + EIP + routes (متعملش apply)
terraform destroy -target=module.network
```
**التحقق:** الـ public بس فيها `0.0.0.0/0 → igw`، الـ private فيها `local` + `pl-` (S3)، والـ default SG من غير rules · **Gotchas:** • "public" = route للـ IGW، مش الاسم • NACL stateless: الرد على ephemeral ports 1024–65535 • `-target` للتعلم بس · **التكلفة:** مجاني؛ NAT ~$0.045/ساعة لكل واحد + $0.045/GB

### 41 — RDS MySQL + نقل الداتا من الـ container
**الهدف:** RDS MySQL 8.4 private/encrypted/PITR بـ parameter group utf8mb4، الـ module بيكتب `DB_*` في SSM، ونقل الداتا بـ freeze → mysqldump → restore عن طريق Session Manager.
**أهم الأوامر:**
```bash
terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg apply -target=module.rds    # أو الـ stack كله
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[?contains(Name, `DB_`)].Name'
aws ssm start-session --target <IID> --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters '{"host":["<RDS>"],"portNumber":["3306"],"localPortNumber":["13306"]}'
export MYSQL_PWD=$(aws ssm get-parameter --name /student-app/lab/app/DB_PASSWORD --with-decryption --query Parameter.Value --output text)
gunzip -c student_app.sql.gz | mysql -h 127.0.0.1 -P 13306 -u student student_app
aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier student-app-lab-mysql --target-db-instance-identifier student-app-lab-mysql-pitr --restore-time <UTC>
```
**التحقق:** `PubliclyAccessible=false`، `StorageEncrypted=true`، backup 7 أيام، row counts متطابقة، `/ready` = ready · **Gotchas:** • dump من غير write freeze = data loss صامت • PITR = instance **جديد** بـ endpoint جديد • `use_secrets_manager` مش متعرّض في stack 40 والـ user data بيقرا SSM بس · **التكلفة:** ~$0.016/ساعة + gp3 ≈ $0.5/يوم؛ Multi-AZ ×2

### 42 — ALB + ASG + Launch Template + ACM/Route 53
**الهدف:** ALB بـ TGs blue/green (`/ready`، 2/2، dereg 30s) و listener weighted، LT بـ IMDSv2 و user data بيقرا IMAGE_URI من SSM، ASG بـ ELB health (grace/warmup 120)، و HTTPS بـ `domain_name`.
**أهم الأوامر:**
```bash
cd infra/terraform/stacks/40-ec2-alb-asg && cp -n terraform.tfvars.example terraform.tfvars   # image_tag = SHA
terraform plan -out=tfplan && terraform apply tfplan
eval "$(terraform output -raw migrate_command)"
curl -s "$(terraform output -raw app_url)/ready" | jq .
aws elbv2 describe-target-health --target-group-arn "$(terraform output -json target_group_arns | jq -r .blue)" --query 'TargetHealthDescriptions[].TargetHealth.State'
gh variable set ALB_LISTENER_ARN --body "$(terraform output -raw listener_arn)"
```
**التحقق:** 2 targets `healthy`، `/metrics` = 404 من الـ ALB، logs في `/student-app/lab/app` · **Gotchas:** • الـ ALB على host port 80 (`-p 80:8080`) • `/ready` عميق + ELB health = الـ fleet كله يتبدّل لو الـ DB وقعت • الـ seed بـ `docker run --rm` مش `docker exec` (config cached) · **التكلفة:** ≈ $0.08/ساعة ≈ $2/يوم للـ stack

### 43 — Golden AMI بـ Packer + Ansible
**الهدف:** AMI فيها Docker + agents بنفس `provision.yml`، تتدّي لـ stack 40 بـ `ami_id` + `golden_ami = true` → instance refresh بـ auto rollback حقيقي (الـ LT اتغيّر).
**أهم الأوامر:**
```bash
cd infra/packer && packer init . && packer validate . && packer build .
AMI=$(jq -r '.builds[-1].artifact_id' manifest.json | cut -d: -f2)
# stack 40 tfvars: ami_id = "<AMI>"  golden_ami = true  → terraform apply
aws autoscaling describe-instance-refreshes --auto-scaling-group-name student-app-lab-blue --max-records 1 --query 'InstanceRefreshes[0].[Status,StatusReason]'
aws ec2 describe-images --owners self --filters Name=tag:Project,Values=student-app --query 'Images[].[ImageId,Name,DeprecationTime]' --output table
aws ec2 deregister-image --image-id <AMI> && aws ec2 delete-snapshot --snapshot-id <SNAP>
```
**التحقق:** `cloud-init-output.log` من غير `dnf install docker`، و boot أسرع (LaunchTime → `boot finished`) · **Gotchas:** • `arch` و root volume (16 ≤ 20) لازم يطابقوا stack 40 • `terraform apply` مبيستناش الـ refresh: بعد auto rollback صلّح `ami_id` قبل أي apply • deregister مبيمسحش الـ snapshot · **التكلفة:** سنتات لكل build + ~$0.05/GB-شهر snapshots

### 44 — Rolling بـ ASG Instance Refresh
**الهدف:** release = `put-parameter` IMAGE_URI + `start-instance-refresh` (Min 100 / Max 150، SkipMatching=false، alarms)، يدوي و بـ `deploy-asg.yml strategy=instance-refresh`، والـ rollback بالـ pointer.
**أهم الأوامر:**
```bash
aws ssm put-parameter --name /student-app/lab/deploy/blue/IMAGE_URI --type String --value <REPO>:<SHA> --overwrite
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --strategy Rolling --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false,"AutoRollback":false,"AlarmSpecification":{"Alarms":["student-app-lab-alb-5xx-ratio","student-app-lab-blue-unhealthy-hosts"]}}'
aws autoscaling describe-instance-refreshes --auto-scaling-group-name student-app-lab-blue --max-records 1 --query 'InstanceRefreshes[0].[Status,PercentageComplete]'
gh workflow run deploy-asg.yml -f strategy=instance-refresh -f image_tag=<SHA> -f min_healthy_percentage=100
bash deploy/scripts/probe.sh "$APP_URL/ready" 0 0.2
aws ssm get-parameter-history --name /student-app/lab/deploy/blue/IMAGE_URI --query 'Parameters[-3:].Value'
```
**التحقق:** الـ probe `failed : 0` والإصدارين مخلوطين ثم الجديد بس · **Gotchas:** • Skip matching (default في الـ console) + LT ثابت = مفيش ولا instance اتبدّلت • AWS auto rollback بيرجّع الـ LT مش الـ image → الـ workflow بيرجّع الـ pointer بنفسه • `SRE_FAULT_BOOT_FAIL` في SSM = عطل config: رجوع الـ image مش هيصلّحه · **التكلفة:** نفس 42 + instance زيادة دقايق

### 45 — Blue/Green بـ اتنين ASG + listener switch
**الهدف:** green جاهز على الـ release الجديد بوزن 0، switch 100/0 → 0/100 في call واحد و rollback فوري؛ Terraform way (tfvars) أو CI way (`bluegreen-switch` + `listener_weights_managed_externally`).
**أهم الأوامر:**
```bash
# tfvars: green_enabled = true  [listener_weights_managed_externally = true → recreate للـ listener + حدّث ALB_LISTENER_ARN]
terraform apply
aws ssm put-parameter --name /student-app/lab/deploy/green/IMAGE_URI --type String --value <REPO>:<SHA> --overwrite
gh workflow run deploy-asg.yml -f strategy=bluegreen-switch -f image_tag=<SHA> -f bake_seconds=300 -f scale_down_old=false
aws elbv2 modify-listener --listener-arn "$L" --default-actions "[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[{\"TargetGroupArn\":\"$TGB\",\"Weight\":100},{\"TargetGroupArn\":\"$TGG\",\"Weight\":0}]}}]"
bash deploy/scripts/version-split.sh "$APP_URL/ready" 50
```
**التحقق:** الـ probe بيقلب من `blue` لـ `green` بـ 0 failures، والـ rollback ثانية · **Gotchas:** • من غير `managed_externally` أول `terraform apply` يرجّع الأوزان (drift) • قارن الـ desired بين اللونين قبل الـ switch (الـ idle ممكن يبقى على min) • متعملش `green_enabled = false` و green live → 503 · **التكلفة:** + لون كامل (~$0.75/يوم)؛ `scale_down_old` بيوفّره ويبطّأ الـ rollback

### 46 — Canary بـ weighted target groups + alarm rollback
**الهدف:** green 10 → 25 → 50 → 100 مع `CANARY_ALARM_NAME` gate بين الخطوات، و abort أوتوماتيك لـ bad release بـ `SRE_FAULT_ERROR_RATE` على green.
**أهم الأوامر:**
```bash
aws ssm put-parameter --name /student-app/lab/app/SRE_FAULT_ERROR_RATE --type String --value 0.5    # امسحه أول ما green يقوم
gh workflow run deploy-asg.yml -f strategy=canary-weights -f image_tag=<SHA> -f canary_steps="10 25 50 100" -f step_seconds=300
aws ssm delete-parameter --name /student-app/lab/app/SRE_FAULT_ERROR_RATE
bash deploy/scripts/probe.sh "$APP_URL/login" 0 0.05
k6 run -e BASE_URL="$APP_URL" -e CANARY_COLOR=green -e EXPECT_CANARY_PCT=10 -e TOLERANCE_PCT=5 loadtest/k6/canary-watch.js
aws cloudwatch describe-alarms --alarm-names student-app-lab-alb-5xx-ratio --query 'MetricAlarms[0].StateValue'
```
**التحقق:** `canary aborted at 10%: alarm student-app-lab-alb-5xx-ratio - 100% back on blue` · **Gotchas:** • الـ alarm الافتراضي ALB-wide: 10% × 5% errors = 0.5% بيعدّي → per-TG alarm أدق • ALB metrics 1-min + window 5 دقايق = `step_seconds` 300 • الـ stickiness بتكسب على الأوزان؛ وعلى الـ `*_external` listener بتتطبّق وقت الإنشاء بس (بعد كده CLI) · **التكلفة:** نفس 45 (~20+ دقيقة لونين)

### 47 — Rolling deploy بـ Ansible (serial + drain)
**الهدف:** in-place على الـ ASG: migrate مرة، suspend processes، لكل instance (serial 1): drain → `docker run --name student-app` → `/ready` → register + `target-in-service`، ثم IMAGE_URI و resume.
**أهم الأوامر:**
```bash
cd infra/ansible && ansible-inventory --graph
TG=$(terraform -chdir=../terraform/stacks/40-ec2-alb-asg output -json target_group_arns)
BUCKET=$(terraform -chdir=../terraform/bootstrap output -raw ansible_ssm_bucket)
ansible-playbook playbooks/rolling-asg.yml -e app_image=<REPO>:<SHA> -e "{\"rolling_target_group_arns\": $TG}" -e ssm_bucket_name=$BUCKET
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-blue --query 'AutoScalingGroups[0].SuspendedProcesses'
aws autoscaling resume-processes --auto-scaling-group-name student-app-lab-blue     # لو الـ play وقف
```
**التحقق:** probe = 0 failures، `SuspendedProcesses` فاضية، و re-run = no-op (`end_host`) · **Gotchas:** • credentials بتاعتك (RegisterTargets/SuspendProcesses) مش الـ deploy role • فشل = host بره الـ TG + processes متعلقة (مقصود) • rollback بنفس الـ image القديمة بيعمل `end_host` للـ host المتشال → سجّله بإيدك · **التكلفة:** صفر زيادة (capacity N−1 أثناء الـ roll)

### 48 — Autoscaling تحت load
**الهدف:** target tracking على CPU (50%) و ALBRequestCountPerTarget (1000/دقيقة)، `autoscale-cpu.js` على `/sre-lab/cpu` بالـ token، timeline الـ scale-out/in، و Spot بـ mixed instances.
**أهم الأوامر:**
```bash
TOKEN=$(terraform -chdir=infra/terraform/stacks/40-ec2-alb-asg output -raw sre_lab_token)
k6 run -e BASE_URL="$APP_URL" -e LAB_TOKEN="$TOKEN" -e RATE=4 -e CPU_MS=200 -e DURATION=20m loadtest/k6/autoscale-cpu.js
k6 run -e BASE_URL="$APP_URL" -e LOADTEST_USERS=20 -e VUS=60 -e DURATION=15m loadtest/k6/load.js
aws autoscaling describe-scaling-activities --auto-scaling-group-name student-app-lab-blue --max-items 5 --query 'Activities[].[StartTime,Cause]'
aws cloudwatch describe-alarms --alarm-name-prefix TargetTracking-student-app-lab-blue --query 'MetricAlarms[].[AlarmName,StateValue]'
# tfvars: detailed_monitoring = true   (CPU كل دقيقة → CPU policy أسرع، بفلوس)
# tfvars: spot_enabled = true  spot_instance_types = ["t3.micro","t3a.micro","t2.micro"]   (capacity_rebalance بيتفعّل معاه)
```
**التحقق:** `instance serving traffic: <hostname>` في k6، desired بيطلع وبعدين ينزل (أبطأ) · **Gotchas:** • الـ default CPU كل 5 دقايق (`detailed_monitoring = false`) — الـ requests policy أسرع • `t3` standard credits بتخلص → CPU metric مضلل (`CPUCreditBalance`) • Spot = كله Spot (on-demand base 0)؛ الـ base مش متعرّض في stack 40 → `on_demand_base_capacity` في `module "asg_*"` · **التكلفة:** instances زيادة بالثانية؛ Spot خصم ~60–70%

### 49 — ElastiCache Redis للـ sessions/cache
**الهدف:** قيس الأول (DB sessions = write لكل صفحة، `db/heavy` = query تقيلة)، فعّل `redis_enabled` (Valkey) + instance refresh، اتأكد من phpredis و `tls://`، `migrate --isolated`، وقارن بالأرقام.
**أهم الأوامر:**
```bash
k6 run -e BASE_URL="$APP_URL" -e VUS=40 -e DURATION=10m -e TEST_ID=db-sessions --summary-export loadtest/results/49-before-load.json loadtest/k6/load.js
k6 run -e BASE_URL="$APP_URL" -e LAB_TOKEN="$TOKEN" -e TARGET=db-heavy -e MAX_RATE=60 -e DURATION=10m loadtest/k6/breakpoint.js
# tfvars: redis_enabled = true [redis_transit_encryption = true] → terraform apply
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"SkipMatching":false}'
aws ssm send-command --instance-ids <IID> --document-name AWS-RunShellScript --parameters 'commands=["docker exec student-app php -m | grep -i redis"]'
docker run --rm valkey/valkey:8 valkey-cli -h <ENDPOINT> -p 6379 INFO keyspace        # على instance
```
**التحقق:** RDS `WriteIOPS` نزل في `load.js`، `db0` keys بتزيد، و `db/heavy` تقريباً زي ما هو · **Gotchas:** • الـ env بيتقري وقت الـ boot: refresh إجباري، والـ fleet المخلوط = logout مرة • `redis_enabled = false` في apply واحد = 500 لحد الـ refresh (رجّع SSM + refresh الأول) • node واحد من غير replica، والـ sessions والـ cache على نفس الـ memory (evictions) · **التكلفة:** Valkey `cache.t4g.micro` ~$0.0128/ساعة ≈ $0.31/يوم
