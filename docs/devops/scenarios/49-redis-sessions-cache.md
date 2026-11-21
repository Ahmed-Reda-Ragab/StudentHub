# 49 — ElastiCache Redis للـ sessions/cache (ندوّر على الـ bottleneck)

> **الهدف في سطر:** متضيفش Redis "عشان كله بيضيفه": **قيس الأول** — k6 load بـ `SESSION_DRIVER=database` (row update في MySQL مع كل صفحة) و `/sre-lab/db/heavy`، اقرا metrics الـ RDS والـ ALB، وبعدين فعّل `redis_enabled` (**Valkey**) → `SESSION_DRIVER`/`CACHE_STORE=redis`، اتأكد من الـ phpredis في الـ image، افهم الـ `tls://`، استخدم `migrate --isolated`، وقيس تاني وقارن بأرقام — مع ملاحظات cache stampede والـ TTL.
> **المستوى:** Advanced · **الوقت:** ~3–4 ساعات · **التكلفة التقريبية:** ~$0.3–0.4/يوم للـ cache (`cache.t4g.micro` — تقريبي، راجع صفحة الأسعار) + stack 40
> **بيعتمد على:** [42](42-alb-asg-launch-template.md) · [41](41-rds-mysql.md) · [48](48-autoscaling-under-load.md) · [74 — Load testing](74-load-testing-k6.md) · **الملفات في الـ repo:** [`modules/elasticache-redis/main.tf`](../../../infra/terraform/modules/elasticache-redis/main.tf) · [`modules/elasticache-redis/variables.tf`](../../../infra/terraform/modules/elasticache-redis/variables.tf) · [`stacks/40-ec2-alb-asg/ssm.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/ssm.tf) · [`stacks/40-ec2-alb-asg/main.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/main.tf) · [`config/session.php`](../../../config/session.php) · [`config/cache.php`](../../../config/cache.php) · [`config/database.php`](../../../config/database.php) · [`app/Http/Controllers/SreLabController.php`](../../../app/Http/Controllers/SreLabController.php) · [`app/Http/Middleware/PreventDuplicateSubmissions.php`](../../../app/Http/Middleware/PreventDuplicateSubmissions.php) · [`docker/Dockerfile`](../../../docker/Dockerfile)

## 1) الفكرة (Concepts)

| المصطلح | المعنى |
|---|---|
| `SESSION_DRIVER=database` | الـ session في جدول `sessions` في MySQL. الـ handler بيكتب (insert/update `payload` و `last_activity`) في آخر **كل request في الـ web group** |
| `CACHE_STORE=database` | الـ cache (والـ locks في `cache_locks`) في MySQL. مين بيستخدمه هنا؟ الـ login throttle (`RateLimiter` في `LoginRequest`) و `PreventDuplicateSubmissions` (`Cache::add` لكل form submission) |
| Valkey | fork مفتوح المصدر من Redis (نفس البروتوكول، phpredis شغال عليه)، الـ **default engine** في الـ module، أرخص من Redis OSS على ElastiCache |
| phpredis | الـ PHP extension اللي Laravel بيستخدمه (`REDIS_CLIENT=phpredis` default) |
| Cluster mode disabled | node primary (+ replicas اختياري)، كل الـ keys على shard واحد، وبيدعم multiple DBs (Laravel: DB 0 default، DB 1 للـ cache) |
| Transit encryption | TLS للـ connection — الـ module بيكتب `REDIS_HOST=tls://<endpoint>` |
| Cache stampede | key مشهور بيـ expire → آلاف requests بتحسبه في نفس اللحظة → الداتابيز تقع |

### 1.1 إيه اللي Redis هيصلّحه — وإيه اللي **مش** هيصلّحه

| الحمل على MySQL | مع Redis | ملاحظة |
|---|---|---|
| write لكل صفحة (session) | ✅ بيروح Redis | ده أكبر مكسب للـ RDS الصغير |
| login throttle + duplicate-submission locks | ✅ Redis (atomic، سريع) | |
| `cache_locks` لـ `migrate --isolated` | ✅ Redis lock حقيقي | CONVENTIONS §2: على `database` الجدول مش موجود في أول migration |
| `/sre-lab/db/heavy` (full scan + `GROUP BY`) | ❌ **مش بيستخدم cache خالص** | محتاج query/index fix، أو `Cache::remember`/`Cache::flexible` حواليه (كود)، أو read replica |
| `/sre-lab/*` و `/ready` | — | بره الـ web group: مبيعملوش session أصلاً |

الهدف من السيناريو: تشوف ده **بالأرقام**، مش تصدّقه.

> 💡 زي ما تعليق [`ssm.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/ssm.tf) بيقول: الـ database sessions **مشتركة أصلاً** بين الـ instances، فالـ scale-in مش بيعمل logout لحد حتى من غير Redis. اللي Redis بيضيفه هو **شيل write من الداتابيز مع كل request** و latency أقل — مش الـ statelessness ولا الـ stickiness.

## 2) المعمارية (Architecture)

```text
 قبل                                                 بعد (redis_enabled = true)
 web request ─► app ─► MySQL: SELECT …              web request ─► app ─► MySQL: SELECT … (الـ business data بس)
                       UPDATE sessions … ◄── كل صفحة                 └──► Valkey DB0: session (TTL = SESSION_LIFETIME 120 دقيقة)
                       cache / cache_locks                                 Valkey DB1: cache, throttle, submission locks

 Terraform: module "redis" (count = redis_enabled)
   aws_elasticache_replication_group  student-app-lab-cache  engine valkey · cache.t4g.micro · 1 node (no replica)
                                      at-rest encrypted · transit (redis_transit_encryption) · no snapshots
   SG student-app-lab-cache: 6379 من student-app-lab-app بس      subnet group: private subnets
   SSM /student-app/lab/app/REDIS_HOST (= host أو tls://host) · REDIS_PORT
   ssm.tf: SESSION_DRIVER = CACHE_STORE = "redis"   ← بيتقروا وقت الـ boot بس → instance refresh إجباري
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 40 شغال بداتا ([42 §6](42-alb-asg-launch-template.md): migrate + `LoadTestSeeder`).
- [ ] k6 على جهازك، و [48](48-autoscaling-under-load.md) مفهوم (الـ scaling ممكن يخبّي الـ bottleneck — §6.1).
- الأدوات: `aws` · `terraform` · `k6` · `jq`.

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
export AWS_REGION=us-east-1
APP_URL=$(terraform output -raw app_url)
TOKEN=$(terraform output -raw sre_lab_token)
mkdir -p ../../../../loadtest/results
```

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 الـ cache بإيدك

1. **EC2 → Security groups → Create**: `student-app-lab-cache` · Inbound: Custom TCP **6379** من SG `student-app-lab-app` · (من غير outbound rules).
2. **ElastiCache → Subnet groups → Create subnet group**: `student-app-lab-cache` · VPC الـ lab · الـ **private** subnets.
3. **ElastiCache → Valkey caches → Create Valkey cache** → **Design your own cache** → Creation method: **Cluster cache** → **Cluster mode: Disabled** → Name `student-app-lab-cache` → Location: **AWS Cloud** · ⬜ Multi-AZ · ⬜ Auto-failover → Engine version: الأحدث · Port **6379** · Node type **cache.t4g.micro** · **Number of replicas: 0** → Subnet group: `student-app-lab-cache` → Next → ✅ Encryption at rest · Encryption in transit: ⬜ (أو ✅ مع Access control: **No access control** — شوف §5.3) · Security groups: `student-app-lab-cache` (شيل الـ default) · ⬜ Enable automatic backups → **Create**.
4. لما يبقى `Available`: خد الـ **Primary endpoint** (من غير `:6379`).

### 4.2 وصّل الـ app (نفس اللي `ssm.tf` والـ module بيكتبوه)

```bash
EP=<PRIMARY_ENDPOINT>             # student-app-lab-cache.xxxxxx.ng.0001.use1.cache.amazonaws.com
P=/student-app/lab/app
aws ssm put-parameter --name $P/REDIS_HOST --type String --value "$EP" --overwrite      # أو "tls://$EP" مع transit encryption
aws ssm put-parameter --name $P/REDIS_PORT --type String --value 6379 --overwrite
aws ssm put-parameter --name $P/SESSION_DRIVER --type String --value redis --overwrite
aws ssm put-parameter --name $P/CACHE_STORE --type String --value redis --overwrite
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue --strategy Rolling \
  --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false}'
```

(لو stack 40 بالـ Terraform: دول drift على `aws_ssm_parameter.app` — اعمل الطريقة دي على stack الـ console، أو استخدم §5.)

## 5) الطريقة التانية: Infrastructure as Code (Terraform)

### 5.1 الـ module ([`elasticache-redis`](../../../infra/terraform/modules/elasticache-redis/main.tf))

| Input | Default | ملاحظة |
|---|---|---|
| `engine` | **`valkey`** | أو `redis` (validation) |
| `engine_version` | `null` | أحدث version متاح |
| `node_type` | `cache.t4g.micro` | |
| `port` | 6379 | |
| `transit_encryption_enabled` | `false` | stack 40: `redis_transit_encryption` |
| `ssm_prefix` | — | `/student-app/lab/app` |
| ثابت في الـ module | | `num_cache_clusters = 1`، `automatic_failover_enabled = false`، `multi_az_enabled = false`، `at_rest_encryption_enabled = true`، `snapshot_retention_limit = 0`، `apply_immediately = true` |

Stack 40 بيبعت `subnet_ids = private_subnet_ids` و `allowed_security_group_ids = [aws_security_group.app.id]`، وبيضيف `REDIS_*` لـ `local.boot_parameters` (أول instance بعد الـ apply متبوتش قبلهم). الـ app SG عنده أصلاً egress 6379 للـ VPC CIDR.

### 5.2 Apply + refresh

```bash
# terraform.tfvars:  redis_enabled = true      (اختياري: redis_transit_encryption = true)
terraform plan -out=tfplan
#   + module.redis[0]: replication group, subnet group, SG + rule, ssm REDIS_HOST/REDIS_PORT
#   ~ aws_ssm_parameter.app["SESSION_DRIVER"], ["CACHE_STORE"]: database → redis
terraform apply tfplan        # ~10 دقايق (ElastiCache)
terraform output -raw redis_endpoint
```

⚠️ الـ instances بتقرا `app.env` **وقت الـ boot بس**، والـ LT متغيّرش → مفيش refresh أوتوماتيك. لازم:

```bash
for c in blue green; do
  aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-$c --strategy Rolling \
    --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false}' 2>/dev/null \
    && echo "refresh started: $c"
done
```

**أثناء الـ refresh الـ fleet مخلوط**: مستخدم عامل login على instance بـ database sessions، الـ request الجاي يروح instance بـ redis → مفيش session → يرجع لصفحة الـ login. ده **logout لمرة واحدة** لكل المستخدمين (k6 هيعدّهم في `session_relogins`). اعمله في وقت هادي، أو اقبله كـ trade-off. (Laravel مفيهوش "dual-read" بين driverين.)

### 5.3 phpredis و TLS

الـ [`Dockerfile`](../../../docker/Dockerfile) بيضيف `apcu` بس، ومعتمد على إن الـ base `serversideup/php:8.3-fpm-nginx-alpine-v5.0.5` فيه `redis` extension جاهز. **اتأكد بنفسك** قبل ما تقلب:

```bash
IID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-blue \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`]|[0].InstanceId' --output text)
CID=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters 'commands=["docker exec student-app php -m | grep -i -E \"^(redis|apcu)$\"","docker exec student-app php --ri redis | head -5"]' \
  --query Command.CommandId --output text); sleep 4
aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" --query StandardOutputContent --output text
```

لو `redis` مش موجود: `RUN install-php-extensions apcu redis` في الـ Dockerfile (نفس سطر الـ apcu) وimage جديدة — **قبل** ما تقلب `SESSION_DRIVER`، وإلا كل الصفحات 500 (`Class "Redis" not found`).

**TLS (`redis_transit_encryption = true`):** الـ module بيكتب `REDIS_HOST=tls://<endpoint>`، و phpredis بيفهم الـ scheme في الـ host ويفتح TLS. [`config/database.php`](../../../config/database.php) مفيهوش `REDIS_SCHEME`، فالـ trick كله في قيمة الـ host. التغيير ده في ElastiCache بيعمل **replace** للـ replication group (endpoint جديد وcache فاضي) — شوف الـ plan. اختبر من instance:

```bash
# Session Manager على instance:
EP=$(grep '^REDIS_HOST=' /opt/student-app/app.env | cut -d= -f2- | sed 's#^tls://##')
docker run --rm valkey/valkey:8 valkey-cli -h "$EP" -p 6379 PING                  # من غير TLS
docker run --rm valkey/valkey:8 valkey-cli -h "$EP" -p 6379 --tls PING            # مع transit encryption
docker run --rm valkey/valkey:8 valkey-cli -h "$EP" -p 6379 INFO keyspace         # db0 (sessions) / db1 (cache)
```

### 5.4 `migrate --isolated` بقى ممكن

مع `CACHE_STORE=redis`، `php artisan migrate --isolated` بياخد atomic lock من الـ cache قبل ما يبدأ؛ أي محاولة تانية في نفس الوقت **مبتشتغلش وبتخرج بـ exit 0**. يعني تقدر تشغّل الـ migrate من أكتر من مكان (deploy على أكتر من instance) من غير ما يجروا مع بعض:

```bash
IMG=$(aws ssm get-parameter --name /student-app/lab/deploy/blue/IMAGE_URI --query Parameter.Value --output text)
IIDS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names student-app-lab-blue \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' --output text)
aws ssm send-command --instance-ids $IIDS --document-name AWS-RunShellScript \
  --parameters "commands=[\"docker run --rm --env-file /opt/student-app/app.env $IMG php artisan migrate --force --isolated\"]" \
  --query Command.CommandId --output text
# get-command-invocation لكل instance: واحدة بتعمل الشغل (أو Nothing to migrate)، والتانية بتتخطى
```

(على `CACHE_STORE=database` وداتابيز فاضية نفس الأمر بيفشل: `cache_locks` مش موجود لسه — CONVENTIONS §2.)

## 6) الـ Deploy — قيس، غيّر، قيس تاني

### 6.1 خلّي التجربة عادلة

- **ثبّت الـ capacity** وقت القياس (وإلا الـ autoscaling يخبّي الفرق): `aws autoscaling suspend-processes --auto-scaling-group-name student-app-lab-blue --scaling-processes AlarmNotification` (وارجع `resume-processes` بعدين).
- نفس الـ VUs ونفس المدة ونفس الـ dataset، و `TEST_ID` مختلف لكل run.
- اقرا الـ server side مع الـ k6 summary (RDS + ALB).

### 6.2 Baseline (database sessions/cache)

```bash
cd ../../../..     # جذر الـ repo
k6 run -e BASE_URL="$APP_URL" -e LOADTEST_USERS=20 -e VUS=40 -e DURATION=10m -e P95_MS=300 -e TEST_ID=db-sessions \
  --summary-export loadtest/results/49-before-load.json loadtest/k6/load.js
k6 run -e BASE_URL="$APP_URL" -e LAB_TOKEN="$TOKEN" -e TARGET=db-heavy -e START_RATE=2 -e MAX_RATE=60 -e DURATION=10m \
  --summary-export loadtest/results/49-before-dbheavy.json loadtest/k6/breakpoint.js
```

### 6.3 اقرا الـ metrics (نفس الـ window بتاع كل run)

```bash
DB=student-app-lab-mysql; S=$(date -u -d '-12 min' +%FT%TZ); E=$(date -u +%FT%TZ)
for M in CPUUtilization DatabaseConnections WriteIOPS ReadIOPS WriteLatency ReadLatency; do
  printf '%-20s ' $M
  aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name $M --dimensions Name=DBInstanceIdentifier,Value=$DB \
    --start-time $S --end-time $E --period 60 --statistics Average Maximum \
    --query 'Datapoints | [max_by(@,&Maximum).Maximum, avg(@[].Average)]' --output text
done
ALB=$(aws elbv2 describe-load-balancers --names student-app-lab-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text | sed 's#.*:loadbalancer/##')
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value=$ALB --start-time $S --end-time $E --period 60 --extended-statistics p95 \
  --query 'sort_by(Datapoints,&Timestamp)[].ExtendedStatistics.p95' --output text
```

والـ slow query log (الـ module بيعمل export لـ `slowquery` و `long_query_time = 1`) — **CloudWatch → Logs Insights** على `/aws/rds/instance/student-app-lab-mysql/slowquery`:

```text
fields @timestamp, @message
| parse @message "# Query_time: * " as qt
| sort qt desc
| limit 10
```

المتوقع: `WriteIOPS` بتتناسب مع الـ page views في `load.js` (الـ sessions)، و `CPUUtilization` بتطلع جامد في الـ `db-heavy` (الـ `GROUP BY user_id` على `subscriptions`)، والـ slow log مليان الـ aggregate. الـ alarm `student-app-lab-rds-cpu` (> 80% لمدة 10 دقايق) ممكن يضرب.

### 6.4 فعّل Redis (§5.2 + refresh) واستنى الـ fleet كله يبقى على الـ env الجديد

```bash
curl -s "$APP_URL/ready" | jq .          # لسه سليم
for i in 1 2 3; do curl -s -c /tmp/cj -b /tmp/cj -o /dev/null -w '%{http_code}\n' "$APP_URL/login"; done
```

### 6.5 نفس الـ runs تاني وقارن

```bash
k6 run -e BASE_URL="$APP_URL" -e LOADTEST_USERS=20 -e VUS=40 -e DURATION=10m -e P95_MS=300 -e TEST_ID=redis-sessions \
  --summary-export loadtest/results/49-after-load.json loadtest/k6/load.js
k6 run -e BASE_URL="$APP_URL" -e LAB_TOKEN="$TOKEN" -e TARGET=db-heavy -e START_RATE=2 -e MAX_RATE=60 -e DURATION=10m \
  --summary-export loadtest/results/49-after-dbheavy.json loadtest/k6/breakpoint.js
for f in before after; do
  jq -r --arg f $f '"\($f): p95=\(.metrics.http_req_duration["p(95)"]|floor)ms  rps=\(.metrics.http_reqs.rate*100|floor/100)  failed=\(.metrics.http_req_failed.value)"' \
    loadtest/results/49-$f-load.json
done
```

| المقياس | قبل (database) | بعد (redis) | تفسيرك |
|---|---|---|---|
| `load.js` p95 / req/s | | | |
| RDS `WriteIOPS` أثناء `load.js` | | | المفروض ينزل جامد |
| RDS `CPUUtilization` أثناء `load.js` | | | |
| `breakpoint.js db-heavy`: الـ rate اللي وقف عنده | | | **المفروض تقريباً نفسه** — مش cached |
| ElastiCache `EngineCPUUtilization` / `CurrConnections` | — | | |

ElastiCache metrics:

```bash
RG=student-app-lab-cache
aws cloudwatch get-metric-statistics --namespace AWS/ElastiCache --metric-name EngineCPUUtilization \
  --dimensions Name=CacheClusterId,Value=$RG-001 --start-time $S --end-time $E --period 60 --statistics Maximum \
  --query 'Datapoints[].Maximum' --output text
aws elasticache describe-cache-clusters --show-cache-node-info --query 'CacheClusters[?ReplicationGroupId==`student-app-lab-cache`].[CacheClusterId,CacheNodeType,Engine,EngineVersion,CacheClusterStatus]' --output table
```

(أول node في replication group اسمه `<rg-id>-001` — اتأكد من الـ output التاني.) بص كمان على `CacheHits`/`CacheMisses`، `CurrItems`، `BytesUsedForCache`، و `Evictions`.

### 6.6 Cache stampede و TTL — ملاحظات للكود

- لو حطيت `/sre-lab/db/heavy` (أو dashboard شبهه) ورا `Cache::remember('heavy', 60, …)`: كل 60 ثانية الـ key بيـ expire، وكل الـ requests اللي جت في اللحظة دي بتحسبه مع بعض = stampede على الـ RDS.
  - `Cache::flexible('heavy', [60, 120], fn () => …)` (stale-while-revalidate): بين 60 و 120 ثانية بيرجّع القيمة القديمة ويحسب الجديدة في الخلفية.
  - أو `Cache::lock('heavy:refresh')->block(…)`: واحد بس يحسب والباقي يستنى/ياخد القديم.
  - **Jitter** في الـ TTL (`60 + random_int(0, 15)`) عشان الـ keys متـ expire كلها في نفس الثانية.
- الـ sessions والـ cache على **نفس الـ node** (DB 0 و 1 = نفس الـ memory). لو الـ memory اتملت، الـ eviction policy (parameter group: `maxmemory-policy`) ممكن تشيل **sessions** = logout عشوائي. راقب `Evictions` و `DatabaseMemoryUsagePercentage`؛ في production افصلهم (cluster للـ sessions بـ `noeviction` أو `volatile-*`، وcluster للـ cache).
- Node واحد ومن غير replica (`num_cache_clusters = 1`): الـ node يقع أو maintenance = كل المستخدمين logout والـ cache بارد. الـ module واخد القرار ده للـ lab ("Losing it logs users out, nothing more")؛ production = replica + `automatic_failover_enabled` + `multi_az_enabled`.

## 7) التحقق (Verify)

```bash
aws ssm get-parameters --names /student-app/lab/app/SESSION_DRIVER /student-app/lab/app/CACHE_STORE /student-app/lab/app/REDIS_HOST \
  --query 'Parameters[].[Name,Value]' --output table
aws elasticache describe-replication-groups --replication-group-id student-app-lab-cache \
  --query 'ReplicationGroups[0].{status:Status,engine:Engine,transit:TransitEncryptionEnabled,atRest:AtRestEncryptionEnabled,primary:NodeGroups[0].PrimaryEndpoint.Address}'
# بعد login (k6 أو المتصفح): مفيش rows جديدة في sessions — النفق والـ MYSQL_PWD زي 41 §6.1
mysql -h 127.0.0.1 -P 13306 -u student student_app -e 'SELECT COUNT(*), MAX(FROM_UNIXTIME(last_activity)) FROM sessions'
```

وعلى instance: `docker run --rm valkey/valkey:8 valkey-cli -h <EP> INFO keyspace` → `db0:keys=…` بيزيد مع كل login.

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Redis مش reachable | امسح الـ ingress rule 6379 من `student-app-lab-cache` (Console) لدقيقتين | كل صفحات الـ web → 500 (الـ session middleware مش قادر يوصل)، بس **`/ready` سليم** (DB ping بس) → الـ ALB والـ ASG مش شايفين حاجة. الـ 5xx alarm هو اللي يصحى. رجّع بـ `terraform apply`. سؤال تصميم: هل `/ready` لازم يشيك Redis؟ (لو أيوه → Redis يقع = كل الـ fleet unhealthy — نفس cascade [41](41-rds-mysql.md)) |
| Reboot الـ node | `aws elasticache reboot-cache-cluster --cache-cluster-id student-app-lab-cache-001 --cache-node-ids-to-reboot 0001` | errors لحد ما يرجع، وبعدين كل المستخدمين logout (sessions راحت، مفيش persistence) |
| `redis_enabled = false` في apply واحد | §10 | Terraform بيقلب `SESSION_DRIVER` لـ database **ويمسح الـ cluster** في نفس الـ apply، والـ instances لسه على `app.env` القديم (redis) → 500 لحد الـ refresh |
| من غير phpredis | (لو الـ image مفيهاش الـ extension) | `Class "Redis" not found` في كل صفحة — عشان كده §5.3 قبل §5.2 |

## 9) الرجوع (Rollback)

الترتيب الآمن (من غير شباك 500):

```bash
P=/student-app/lab/app
aws ssm put-parameter --name $P/SESSION_DRIVER --type String --value database --overwrite
aws ssm put-parameter --name $P/CACHE_STORE --type String --value database --overwrite
for c in blue green; do
  aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-$c --strategy Rolling \
    --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":150,"InstanceWarmup":120,"SkipMatching":false}' 2>/dev/null
done
# استنى الـ refreshes تخلص، وبعدين:
# terraform.tfvars: redis_enabled = false   →  terraform apply   (الـ SSM values هتطابق، والـ cluster يتمسح)
```

(الـ sessions اللي في Redis بتضيع → logout لمرة. الـ sessions القديمة في MySQL ممكن تكون لسه صالحة لو `SESSION_LIFETIME` مخلصش.)

## 10) المسح (Teardown) ⚠️

استخدم ترتيب §9 (مش `redis_enabled = false` على طول). وبعدها:

```bash
aws elasticache describe-replication-groups --query 'ReplicationGroups[?starts_with(ReplicationGroupId, `student-app`)].ReplicationGroupId'
aws elasticache describe-snapshots --query 'Snapshots[?starts_with(SnapshotName, `student-app`)].SnapshotName'
aws ssm get-parameters-by-path --path /student-app/lab/app --query 'Parameters[?starts_with(Name, `/student-app/lab/app/REDIS`)].Name'
aws autoscaling resume-processes --auto-scaling-group-name student-app-lab-blue      # لو علّقت AlarmNotification في §6.1
```

Console: امسح الـ cache والـ subnet group والـ SG اللي عملتهم في §4. والـ stack كله: [42 §10](42-alb-asg-launch-template.md).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| ElastiCache Valkey `cache.t4g.micro` | ~$0.0128/ساعة ≈ $0.31/يوم (الـ README بتاع الـ stack: +0.013/ساعة) |
| Redis OSS نفس الـ node | ~$0.016/ساعة |
| Replica (production) | ×2 |
| Backups | مقفولة (`snapshot_retention_limit = 0`) |
| ElastiCache Serverless (بديل) | بالـ GB-hour + ECPUs — فيه حد أدنى للتخزين؛ قارن قبل ما تختار للـ lab |
| Data transfer cross-AZ (app في AZ والـ node في التانية) | ~$0.01/GB في كل اتجاه |

## 12) أسئلة Interview

<details><summary>إزاي تعرف إن الـ bottleneck في الداتابيز قبل ما تضيف cache؟</summary>

load test على traffic واقعي + قراءة الـ server side: RDS CPU/IOPS/connections/latency، الـ slow query log / Database Insights، ALB p95 per route (أو k6 `name` tags)، و saturation الـ app (PHP-FPM workers). وبعدين تغيير واحد في المرة وقياس تاني بنفس الظروف (capacity ثابتة). هنا الأرقام بتقول: الـ sessions = writes لكل صفحة (Redis بيحلها)، والـ `db/heavy` = query تقيلة (Redis مش بيحلها لوحده).

</details>

<details><summary>Sessions في Redis ولا DB ولا cookie؟</summary>

DB: بسيط ومشترك ومتين، بس write لكل request على أغلى resource عندك. Redis: سريع ومناسب، بس in-memory (eviction/failover = logout) — محتاج replica و eviction policy مناسبة. Cookie (encrypted): stateless تماماً، بس حجم محدود (~4KB) وكل request بيشيله، والـ revocation أصعب. القرار بيعتمد على الـ write rate والـ consistency المطلوبة.

</details>

<details><summary>إيه هو cache stampede وإزاي تمنعه؟</summary>

key مشهور بيـ expire وفجأة كل الـ requests بتعمل miss وبتضرب الـ origin مع بعض. الحلول: stale-while-revalidate (`Cache::flexible`)، lock واحد يحسب (`Cache::lock`)، early/probabilistic refresh، jitter في الـ TTLs، و pre-warming بعد deploy أو flush. وافتكر الـ thundering herd بعد restart للـ cache نفسه.

</details>

<details><summary>ليه `migrate --isolated` محتاج Redis هنا؟</summary>

بياخد atomic lock من الـ cache driver؛ أي تشغيل تاني والـ lock موجود بيتخطى ويخرج بـ success. مع `CACHE_STORE=database` الـ lock محتاج جدول `cache_locks` — اللي بيتعمل **بـ** migration، فعلى داتابيز فاضية الأمر بيفشل (chicken-and-egg). مع Redis الـ lock موجود من غير schema. ده بيخلّي الـ migrations آمنة لو اتشغلت من أكتر من مكان، بس الـ best practice لسه: خطوة واحدة لكل release (CONVENTIONS §2).

</details>

<details><summary>TLS لـ ElastiCache — إيه اللي بيتغير؟</summary>

`transit_encryption_enabled` على الـ replication group (التغيير ممكن يعمل replace = endpoint جديد و cache فاضي)، والـ client لازم يفتح TLS: phpredis بيعمل كده لو الـ host `tls://…` (اللي الـ module بيكتبه في `REDIS_HOST`). فيه overhead CPU بسيط على الـ node والـ client. ومع Valkey/Redis 6+ تقدر تضيف AUTH/RBAC (user groups) فوق الـ TLS.

</details>

<details><summary>إيه الـ failure modes لما Redis يقع؟</summary>

الـ sessions → كل المستخدمين logout أو 500 (حسب الـ driver)، الـ cache → misses والحمل يرجع للداتابيز (ممكن يوقعها لو الـ cache كان بيشيل كتير — cascading)، والـ locks/throttling → سلوك غلط. التخفيف: replica + auto-failover، timeouts قصيرة و retries بـ backoff (الـ config فيه `max_retries` و `decorrelated_jitter`)، circuit breaker، وإن الـ readiness ميعتمدش على Redis إلا لو فعلاً مينفعش تخدم من غيره.

</details>

<details><summary>Valkey ولا Redis OSS؟</summary>

Valkey fork مفتوح (BSD) من Redis 7.2 بعد تغيير الـ license، متوافق على مستوى البروتوكول والأوامر (phpredis وclients شغالين)، و AWS مسعّره أرخص على ElastiCache. Redis OSS لو محتاج feature معين أحدث أو توافق تشغيلي. الـ module بيسمح بالاتنين (`engine`)، والـ default Valkey.

</details>

## 13) Checklist

- [ ] قست baseline بـ database sessions/cache (k6 + RDS + ALB + slow log)
- [ ] اتأكدت إن الـ `redis` extension موجود في الـ image
- [ ] عملت Valkey من الـ console مرة، وبالـ Terraform (`redis_enabled`) + instance refresh
- [ ] قست تاني بنفس الظروف وملّيت جدول المقارنة، وفهمت ليه `db/heavy` متحسنش
- [ ] جرّبت `migrate --isolated` على أكتر من instance
- [ ] جرّبت Redis مش reachable وشفت إن `/ready` مش شايفه
- [ ] رجّعت بالترتيب الآمن (SSM + refresh ثم `redis_enabled = false`)
