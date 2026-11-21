# 95 — Database migrations من غير downtime (expand/contract)

> **الهدف في سطر:** تعرف ليه الـ migrations هي أصعب جزء في أي zero-downtime deploy، وتحلل migrations **حقيقية** من الـ repo ده كسرت (أو كانت هتكسر) blue/green و rolling و canary، وتقسّمها expand → backfill → contract، مع online DDL في MySQL 8.4، و `migrate --force` مرة واحدة، و `--isolated`، وحقيقة الـ rollback.
> **المستوى:** Advanced · **الوقت:** ~4 ساعات · **التكلفة التقريبية:** مجاني (محلي) / سنتات لـ RDS snapshots
> **بيعتمد على:** [23](23-bluegreen-single-host.md) · [24](24-canary-single-host.md) · [25](25-rolling-single-host.md) · **الملفات في الـ repo:** [`database/migrations/`](../../../database/migrations) · [`2026_09_30_151013_add_pricing_to_subscriptions_table.php`](../../../database/migrations/2026_09_30_151013_add_pricing_to_subscriptions_table.php) · [`2026_10_01_000000_replace_grade_sections_with_tracks.php`](../../../database/migrations/2026_10_01_000000_replace_grade_sections_with_tracks.php) · [`deploy/ec2/lb/bin/lib.sh`](../../../deploy/ec2/lb/bin/lib.sh) · [`app/Models/Subscription.php`](../../../app/Models/Subscription.php) · [`app/Models/Student.php`](../../../app/Models/Student.php)

## 1) الفكرة (Concepts)

كل استراتيجيات الـ zero-downtime (blue/green، canary، rolling) فيها **فترة الإصدارين بيشتغلوا فيها على نفس الداتابيز**. والكود ممكن يرجع (rollback) في ثانية، لكن الـ schema والـ data **مش بترجع**. يعني:

> **أي migration لازم تشتغل مع الكود القديم والجديد في نفس الوقت.**

| المصطلح | المعنى |
|---|---|
| Expand | تغيير **إضافي** متوافق مع القديم (column nullable، جدول جديد، enum value جديدة) |
| Backfill | ملء الداتا للشكل الجديد — في batches، idempotent |
| Contract | التغيير **الهدّام** (drop، NOT NULL، شيل enum value) — بعد ما محدش بقى بيستخدم القديم |
| Compatibility window | الفترة اللي فيها code N-1 و code N شغالين على schema N |
| Dual write | الكود بيكتب في القديم والجديد مع بعض في فترة الانتقال |
| Online DDL | `ALTER TABLE` من غير ما يقفل الجدول على الـ reads/writes |
| Metadata lock (MDL) | lock بياخده أي `ALTER` في MySQL — حتى الـ INSTANT |

### ترتيب الـ deploy في سكريبتات المعمل

```text
 bluegreen.sh / canary.sh / rolling.sh  (lib.sh → start_slot):
   pull → migrate (بالـ image الجديدة، مرة واحدة) → start new → ready → smoke → switch/weights
          ▲
          └── في اللحظة دي الكود القديم بيخدم 100% من الـ traffic على الـ schema الجديد
              وبعد الـ switch القديم فاضل شغال للـ rollback (KEEP_OLD=true)
```

مصفوفة التوافق اللي لازم تبقى كلها ✅ طول الـ window:

| | schema قبل الـ migration | schema بعد الـ migration |
|---|---|---|
| **code القديم** | ✅ (الوضع الحالي) | **لازم ✅** (من الـ migrate لحد الـ switch + الـ rollback) |
| **code الجديد** | لازم ✅ لو الـ migration ممكن تتأخر/تفشل (مثلاً ECS بيقوم قبل الـ job) | ✅ |

## 2) المعمارية (Architecture): expand/contract على 3 releases

```text
 Release R1 (expand)        backfill (job)            Release R2              Release R3 (contract)
 ───────────────────        ──────────────            ──────────              ─────────────────────
 + price NULL               UPDATE ... WHERE           code: price بس          price NOT NULL
 + commission NULL          price IS NULL              (amount مش مستخدم)       DROP amount
 code: يكتب price،          LIMIT/chunk 1000                                   (بعد ما الـ rollback
 يقرا price ?? amount       idempotent، resumable                              لـ R1 مبقاش وارد)
     │                            │                         │                        │
 v_old + v_R1 ✅            v_R1 ✅                    v_R1 + v_R2 ✅            v_R2 + v_R3 ✅
```

## 3) المتطلبات (Prerequisites)

- [ ] فاهم [23](23-bluegreen-single-host.md) و [24](24-canary-single-host.md) و [25](25-rolling-single-host.md) (مين بيشغّل الـ migrate وإمتى).
- [ ] PHP محلي (Laragon/WSL) + MySQL (محلي أو `docker compose` من [10](10-containerize-app.md)) للتمارين.
- الأدوات: `php artisan`، `mysql` client.

## 4) الطريقة الأولى: AWS Console (يدوي) — قبل migration خطرة على RDS

لما الداتابيز على RDS ([41](41-rds-mysql.md)):

1. **RDS → Databases → `<DB_ID>` → Actions → Take snapshot** قبل أي contract step (الـ automated backups + PITR موجودين، بس الـ manual snapshot بيبقى نقطة رجوع واضحة باسم).
2. **RDS → Databases → `<DB_ID>` → Monitoring / Database Insights (Performance Insights)**: راقب الـ waits (خصوصاً metadata locks) والـ active sessions وقت الـ migration.
3. **RDS → Parameter groups**: اعرف قيمة `lock_wait_timeout` (الافتراضي في MySQL كبير جداً — سنة!) — هنظبطها على مستوى الـ session في الـ migration.
4. للتغييرات الكبيرة (major upgrade أو schema rebuild تقيل): **RDS Blue/Green Deployments** (RDS → Actions → Create Blue/Green Deployment) بيعمل نسخة staging متزامنة بالـ replication وتعمل switchover في حوالي دقيقة — بشرط إن التغيير replication-compatible.

## 5) الطريقة التانية: as Code — تحليل migrations حقيقية من الـ repo

### 5.1 الحالة الأولى: `add_pricing_to_subscriptions_table` (كل حاجة في خطوة واحدة)

```php
// 2026_09_30_151013_add_pricing_to_subscriptions_table.php — up()
Schema::table('subscriptions', function (Blueprint $table) {
    $table->decimal('price', 10, 2)->nullable()->after('ends_on');
    $table->decimal('commission', 10, 2)->nullable()->after('price');
});
DB::table('subscriptions')->update([                         // backfill: UPDATE واحد على الجدول كله
    'price' => DB::raw('coalesce(amount, '.(float) config('subscriptions.pricing.price').')'),
    'commission' => (float) config('subscriptions.pricing.commission'),
]);
Schema::table('subscriptions', function (Blueprint $table) {
    $table->decimal('price', 10, 2)->nullable(false)->change();     // contract
    $table->decimal('commission', 10, 2)->nullable(false)->change(); // contract
    $table->dropColumn('amount');                                    // contract
});
```

الكود القديم (قبل الـ commit ده) كان `Subscription` فيه `#[Fillable(['user_id', 'type', 'start_date', 'ends_on', 'amount', 'note'])]` ومفيهوش `price`. مع blue/green:

| اللحظة | اللي بيحصل |
|---|---|
| `migrate` خلص، الـ live لسه القديم | أي اشتراك/تجديد جديد من الكود القديم: insert من غير `price` → MySQL strict: `Field 'price' doesn't have a default value` → **500**. ولو الكود بعت `amount` → `Unknown column 'amount'` |
| بعد الـ switch | الجديد تمام |
| **rollback** (`rollback.sh`) | بيرجّعك لكود **مكسور** على الـ schema الجديد — الـ rollback "الفوري" بقى وهم |
| canary/rolling | نفس المشكلة بس لدقايق، لنسبة من الـ requests |

ومشاكل تانية في نفس الملف: الـ backfill `UPDATE` واحد على الجدول كله (transaction طويلة، row locks، undo log كبير على جدول كبير)، وبيعتمد على `config()` وقت الـ migrate (بيئتين ممكن يطلّعوا داتا مختلفة).

**التقسيم الصح:**

R1 — expand (migration جديدة، مثال للتمرين):

```php
public function up(): void
{
    Schema::table('subscriptions', function (Blueprint $table) {
        $table->decimal('price', 10, 2)->nullable()->after('ends_on');
        $table->decimal('commission', 10, 2)->nullable()->after('price');
    });
}
```

والكود في R1: بيكتب `price`/`commission` (و `fillable` فيه الاتنين)، وبيقرا `price ?? amount ?? default`. الكود القديم لسه شغال لأن الأعمدة nullable.

Backfill — command منفصل (مش جوه الـ deploy path):

```php
// app/Console/Commands/BackfillSubscriptionPricing.php (تمرين)
$price = (float) config('subscriptions.pricing.price');
$commission = (float) config('subscriptions.pricing.commission');

DB::table('subscriptions')->whereNull('price')->select('id')->orderBy('id')
    ->chunkById(1000, function ($rows) use ($price, $commission) {
        DB::table('subscriptions')
            ->whereIn('id', $rows->pluck('id'))
            ->whereNull('price')                                  // idempotent
            ->update([
                'price' => DB::raw('coalesce(amount, '.$price.')'),
                'commission' => $commission,
            ]);                                                    // commit لكل batch
        usleep(50_000);                                            // throttle
    });
```

R2 — الكود بيستخدم `price`/`commission` بس، و `amount` اتشال من الـ model (`fillable` و `casts`).

R3 — contract (بعد ما R2 اتعمله rollout كامل والـ rollback لـ R1 مبقاش وارد):

```php
public function up(): void
{
    if (DB::table('subscriptions')->whereNull('price')->orWhereNull('commission')->exists()) {
        throw new RuntimeException('Backfill not complete — run subscriptions:backfill-pricing first.');
    }
    DB::statement('SET SESSION lock_wait_timeout = 5');          // متقعدش مستني MDL للأبد
    Schema::table('subscriptions', function (Blueprint $table) {
        $table->decimal('price', 10, 2)->nullable(false)->change();
        $table->decimal('commission', 10, 2)->nullable(false)->change();
        $table->dropColumn('amount');
    });
}
```

### 5.2 الحالة التانية: `replace_grade_sections_with_tracks` (data migration + enum بيتغير في نفس الـ release)

الـ enum `App\Enums\Section` القديم كان `grade_1`، `grade_2_science`، `grade_2_arts`، `grade_3_science`، `grade_3_math`، `grade_3_arts`. الجديد: `science`، `math`، `arts`، `azhar_science`، `azhar_arts`، `track_*`. والـ migration بتحوّل `grade_3_*` لـ `science/math/arts` وبتخلي الباقي `NULL` مع ملاحظة في `notes`.

`Student` بيعمل cast لـ `section` → `Section::class`، والـ enum cast في Eloquent بيستخدم `from()` → قيمة مش معروفة = `ValueError` = **500**.

| اللحظة | اللي بيحصل |
|---|---|
| بعد الـ migrate، الـ live القديم | أي صفحة بتقرا طالب `section='science'` → الـ enum القديم معندوش `science` → 500 |
| الكود القديم بيكتب في الـ window | بيكتب `grade_2_science` **بعد** ما الـ migration خلصت → الصف ده عمره ما هيتحوّل، والكود الجديد هيقع عليه بعد الـ switch |
| rollback | الكود القديم + داتا جديدة = 500 على كل طالب اتحوّل |
| `down()` | lossy: الـ `DROPPED` بقوا NULL ومينفعش يرجعوا، والـ `MAPPED` العكسي بيحوّل **كل** `science` (حتى اللي اتعمل جديد بالكود الجديد) لـ `grade_3_science` |

وكمان الـ migration ملفوفة كلها في `DB::transaction` → على جدول كبير transaction واحدة طويلة (الـ `chunkById` جواها مش بيقصّر مدة الـ locks لأن الـ commit في الآخر).

**التقسيم الصح:**

1. **R1 (expand في الكود):** الـ enum **superset** — فيه القيم القديمة والجديدة، والكود الجديد بيكتب القيم الجديدة بس، والـ UI بيعرض الاتنين. ده آمن مع الـ schema الحالي ومع الكود القديم (اللي بيكتب قيم قديمة لسه مفهومة).
2. **Backfill:** نفس منطق الـ migration بس batches و commit لكل batch (migration منفصلة بعد R1 أو command).
3. **تحقق:** `SELECT section, COUNT(*) FROM students GROUP BY section;` — مفيش `grade_%`.
4. **R2 (contract):** شيل القيم القديمة من الـ enum.

> نفس النمط في [`convert_student_sections_to_fixed_list`](../../../database/migrations/2026_09_30_180000_convert_student_sections_to_fixed_list.php) (free text → قيم ثابتة: الكود القديم بيكتب نص حر في الـ window والجديد مش هيعرف يقراه) وفي [`recalculate_subscription_dates_to_calendar_months`](../../../database/migrations/2026_09_30_153943_recalculate_subscription_dates_to_calendar_months.php) (تغيير **معنى** الداتا من 30 يوم لشهر تقويمي: الكود القديم في الـ window بيكتب صفوف بالمعنى القديم). أي data migration بتغيّر المعنى لازم الكود يتحوّل الأول، والـ backfill يبقى قابل للتكرار بعد الـ rollout الكامل.

### 5.3 جدول العمليات: آمنة في خطوة واحدة ولا لأ؟

| العملية | خطوة واحدة؟ | الطريقة |
|---|---|---|
| Add column nullable / بـ default | ✅ | INSTANT في MySQL 8.4 |
| Add column NOT NULL من غير default | ❌ | nullable → backfill → NOT NULL |
| Drop column | ❌ | release يبطّل يستخدمه (والـ model ميكتبوش) → drop في release بعدها |
| Rename column | ❌ | column جديد + dual write + backfill + تحويل القراءة + drop القديم |
| Change type | ❌ | column جديد بنفس الأسلوب |
| Add index | ✅ غالباً | online (`INPLACE`، `LOCK=NONE`)؛ على جداول كبيرة راقب الـ I/O |
| Add unique | ⚠️ | الداتا لازم تكون نضيفة، والكود القديم ممكن يكتب duplicates في الـ window |
| Add foreign key | ⚠️ | validation على الجدول كله + locks |
| Enum: إضافة قيمة | ✅ (لو الكود القديم بيتجاهلها) | |
| Enum: شيل/تغيير قيمة | ❌ | superset → backfill → شيل |
| Rename table | ❌ | جدول جديد + dual write، أو view مؤقت |

> 💡 في الـ production الـ `Model::shouldBeStrict()` **مقفول** ([`AppServiceProvider`](../../../app/Providers/AppServiceProvider.php): `! isProduction()`)، فقراية attribute مش موجود بترجع `null` بصمت بدل exception — يعني column اتشال ممكن يبان كـ "داتا فاضية" في القراية، بينما الـ writes بتقع بـ SQL error. الأعطال دي بتبقى أصعب في الكشف.

### 5.4 `migrate --force` مرة واحدة لكل release

- فين بيحصل عندنا: [`deploy-build-on-server.sh`](../../../deploy/ec2/deploy-build-on-server.sh) و [`deploy-pull-image.sh`](../../../deploy/ec2/deploy-pull-image.sh) (`compose run --rm --no-deps app php artisan migrate --force`)، `migrate()` في [`lib.sh`](../../../deploy/ec2/lb/bin/lib.sh) (مع أول slot في rolling بس)، ECS one-off task ([52](52-ecs-migrations-and-exec.md))، Helm hook Job ([65](65-helm-chart.md)).
- **ممنوع** عند الـ boot (`AUTORUN_LARAVEL_MIGRATION=false` في الـ Dockerfile) — N replicas = N migrators بيتسابقوا.
- `--force` لأن `APP_ENV=production` بيطلب تأكيد تفاعلي من غيره.
- قبل أي PR: `php artisan migrate --pretend` (يطبع الـ SQL من غير تنفيذ) و `php artisan migrate:status`.

**`--isolated`** بياخد cache lock عشان migrator واحد بس يشتغل (لو حصل تشغيل متوازي). المشكلة ([CONVENTIONS §2](../CONVENTIONS.md)): مع `CACHE_STORE=database` الـ lock محتاج جدول `cache_locks`، والجدول ده بيتعمل في [`0001_01_01_000001_create_cache_table.php`](../../../database/migrations/0001_01_01_000001_create_cache_table.php) نفسها → على داتابيز فاضية `migrate --isolated` بيقع (chicken-and-egg). استخدمه بس لما الـ cache على Redis ([49](49-redis-sessions-cache.md)) أو بعد أول migration. (للمعلومة: الـ automation بتاعة serversideup لما بتتفعّل بـ isolation بتتخطى الـ flag في أول deploy لنفس السبب — بس إحنا قافلين الـ automation دي أصلاً.)

### 5.5 MySQL 8.4 online DDL

| النوع | أمثلة | الأثر |
|---|---|---|
| `ALGORITHM=INSTANT` | add column (أي مكان من 8.0.29)، drop column (8.0.29+)، rename column، set/drop default، إضافة قيم في آخر ENUM | metadata بس — ثواني حتى على جداول ضخمة (في حدود 64 row version للجدول) |
| `ALGORITHM=INPLACE` | add index، `NULL → NOT NULL` (بيعمل rebuild) | من غير ما يقفل الـ DML غالباً، بس I/O تقيل ووقت طويل |
| `ALGORITHM=COPY` | change column type | بيعمل نسخة كاملة ويقفل الـ writes — ممنوع على جداول كبيرة في الـ production |

الـ Blueprint في Laravel مش بيخليك تحدد الـ algorithm. لما يفرق معاك، اكتبه صريح عشان MySQL **يرفض** بدل ما يعمل COPY بصمت:

```php
DB::statement('SET SESSION lock_wait_timeout = 5');
DB::statement('ALTER TABLE subscriptions ADD COLUMN price DECIMAL(10,2) NULL AFTER ends_on, ALGORITHM=INSTANT');
```

**فخ الـ metadata lock:** حتى الـ INSTANT محتاج exclusive MDL للحظة. لو فيه transaction طويلة (report تقيل، `/sre-lab/db/heavy`، backup من غير `--single-transaction`) ماسكة shared MDL على الجدول، الـ `ALTER` بيستنى — **وكل query جديدة على الجدول بتقف ورا الـ ALTER** → outage من migration "instant". الحماية: `lock_wait_timeout` صغير + retry، وتشوف قبلها:

```sql
SELECT id, time, state, LEFT(info, 80) FROM information_schema.processlist WHERE command <> 'Sleep' ORDER BY time DESC;
SELECT * FROM performance_schema.metadata_locks WHERE object_name = 'subscriptions';
```

للجداول الضخمة (ملايين الصفوف) والتغييرات اللي مش INSTANT: `gh-ost` أو `pt-online-schema-change` (نسخة ظل + sync + cut-over).

### 5.6 الـ backfills الطويلة

- **Batches صغيرة** (500–5000) و **commit لكل batch** — مش `DB::transaction` حوالين الكل (عكس الـ migrations الحالية في الـ repo).
- **Idempotent** (`WHERE price IS NULL`) و **resumable** (بالـ `id`) — لو اتقطع تكمّل.
- **Throttle** (`usleep`) وراقب الـ replication lag لو فيه replicas.
- **بره الـ deploy path**: command أو queue job — الـ deploy مش لازم يستنى ساعة، ومفيش timeout يقطع الـ migration في النص.

### 5.7 حقيقة الـ rollback

- `migrate:rollback` في الـ production نادراً ما يكون آمن: الـ `down()` في `add_pricing` بيرجّع `amount` من `price` ويمسح `price` و **`commission`** (داتا بتضيع)، والـ `down()` في `replace_grade_sections` lossy زي ما شفنا.
- القاعدة: **roll forward** — migration جديدة بتصلّح. والـ code rollback من غير schema rollback هو الطبيعي، وده بالظبط سبب الـ backward compatibility.
- قبل الـ contract: snapshot / backup + PITR (RDS) — ده الـ rollback الحقيقي لو حصلت كارثة داتا.

## 6) الـ Deploy — تمرين عملي

### 6.1 شوف الـ SQL قبل ما يتنفذ

```bash
php artisan migrate:status
php artisan migrate --pretend
```

### 6.2 اكسر blue/green بـ migration مش متوافقة (branch تجريبي)

1. `git switch -c lab/break-migration`
2. ضيف migration بتعمل rename لعمود الكود الحالي بيكتبه، مثلاً `students.phone` → `mobile`:
   ```bash
   php artisan make:migration rename_students_phone_to_mobile --table=students
   ```
   وجواها `$table->renameColumn('phone', 'mobile');` (من غير ما تغيّر الكود).
3. ابني image `student-app:break` من الـ branch ده، وشغّل على الستاك (EC2 أو `lab-integration` في branch):
   ```bash
   SKIP_PULL=true bash deploy/ec2/lb/bin/bluegreen.sh student-app:break
   ```
4. **المتوقع:** الـ smoke (`/up`، `/ready`، `/login`) هيعدّي — مبيلمسوش `students`. بعد الـ switch: صفحات الطلاب بتعرض التليفون فاضي (strict mode مقفول في الـ production)، وأي create/edit لطالب بيقع بـ `Unknown column 'phone'`. والـ `rollback.sh` بيرجّعك لكود بيعمل نفس الحاجة. اللي بيكشف ده traffic حقيقي بيعمل login ويلمس صفحات الطلاب (k6 في `loadtest/k6/`، [CONVENTIONS §10](../CONVENTIONS.md)) أو الـ error-rate metrics — مش الـ health checks.
5. الإصلاح الصح: roll forward بـ migration ترجّع الاسم، وبعدين أعد التغيير بـ expand/contract (add `mobile` + dual write + backfill + switch reads + drop `phone`).

## 7) التحقق (Verify)

```sql
SHOW CREATE TABLE subscriptions\G
SELECT COLUMN_NAME, IS_NULLABLE, COLUMN_DEFAULT FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA = 'student_app' AND TABLE_NAME = 'subscriptions';
SELECT section, COUNT(*) FROM students GROUP BY section;
SELECT COUNT(*) FROM subscriptions WHERE price IS NULL;
```

```bash
php artisan migrate:status          # كل الـ migrations Ran، ومفيش Pending
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر | المتوقع |
|---|---|---|
| Migration بتكسر الكود القديم | §6.2 | smoke بيعدّي، المستخدمين بيقعوا، والـ rollback مش بينقذ |
| MDL pile-up | session 1: `START TRANSACTION; SELECT * FROM subscriptions LIMIT 1;` (سيبها مفتوحة) · session 2: `ALTER TABLE subscriptions ADD COLUMN x INT NULL, ALGORITHM=INSTANT;` · session 3: `SELECT COUNT(*) FROM subscriptions;` | session 2 و 3 واقفين (`Waiting for table metadata lock`) لحد `COMMIT` في session 1. كرر بـ `SET SESSION lock_wait_timeout=5;` في session 2 → بيفشل بسرعة بدل ما يوقف الكل. نضّف بعدها: `ALTER TABLE subscriptions DROP COLUMN x;` |
| `--isolated` على داتابيز فاضية | `docker compose run --rm app php artisan migrate --force --isolated` بعد `docker compose down -v && docker compose up -d --wait` | بيقع لأن `cache_locks` مش موجود |
| `ALGORITHM=INSTANT` على تغيير مش instant | `ALTER TABLE subscriptions MODIFY note VARCHAR(500) NULL, ALGORITHM=INSTANT;` | MySQL بيرفض بـ error (أحسن من COPY بصمت)، والجدول ميتغيرش |

## 9) الرجوع (Rollback)

1. **Code rollback** (`rollback.sh` / redeploy الـ SHA القديم) — بينفع بس لو الـ migration كانت expand.
2. **Roll forward** بـ migration تصلّح — الطريق الطبيعي.
3. **Restore** (snapshot / PITR على RDS، أو `backup-mysql-to-s3.sh restore` في [27](27-mysql-backup-restore.md)) — للكوارث بس، وبيرجّعك لنقطة زمنية (داتا بعدها بتضيع).

## 10) المسح (Teardown) ⚠️

```bash
git switch devops-lab && git branch -D lab/break-migration
docker image rm student-app:break 2>/dev/null || true
```

لو عملت RDS manual snapshots للتجربة: **RDS → Snapshots → Manual** → امسحها (بتتحاسب على الـ storage).

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (راجع صفحة الأسعار) |
|---|---|
| تمارين محلية / CI | مجاني |
| RDS manual snapshots | بالـ GB/شهر بعد حجم الداتابيز المجاني للـ backups |
| RDS Blue/Green Deployment | تمن الـ instance الإضافي طول ما البيئة الخضرا موجودة |

## 12) أسئلة Interview

<details><summary>اشرح expand/contract بمثال.</summary>

عايز تحوّل `amount` لـ `price` NOT NULL. R1: ضيف `price` nullable، والكود يكتب فيه ويقرا `price ?? amount`. Backfill في batches. R2: الكود يعتمد على `price` بس. R3 (بعد ما الـ rollback لـ R1 مبقاش وارد): `NOT NULL` + drop `amount`. في كل لحظة الإصدارين الشغالين متوافقين مع الـ schema، فـ blue/green و canary والـ rollback شغالين.

</details>

<details><summary>ليه الـ code rollback سهل والـ schema rollback صعب؟</summary>

الكود stateless: ترجع الـ image القديمة وخلاص. الـ schema فيه **داتا** اتكتبت بالشكل الجديد بعد الـ migration؛ الـ `down()` غالباً lossy (بيمسح أعمدة فيها داتا جديدة)، وبياخد locks، ومش متجرّب. عشان كده: migrations backward compatible، والـ "rollback" للـ schema = migration جديدة لقدام، والـ restore للكوارث.

</details>

<details><summary>إيه الـ metadata lock trap في MySQL؟</summary>

أي `ALTER` (حتى INSTANT) محتاج exclusive MDL. لو فيه transaction طويلة ماسكة shared MDL، الـ ALTER بيستنى، وكل الـ queries الجديدة على الجدول بتتصف وراه → التطبيق كله يقف. الحل: `lock_wait_timeout` صغير في session الـ migration + retry، تشوف الـ long transactions قبلها، وتشغّل الـ migrations في أوقات الـ traffic الأقل.

</details>

<details><summary>إزاي تشغّل backfill على 50 مليون صف؟</summary>

بره الـ deploy (job/command)، batches بالـ primary key مع commit لكل batch، idempotent بشرط (`WHERE new_col IS NULL`)، throttling ومراقبة الـ replication lag والـ CPU، قابل للاستكمال، ومعاه metric/لوج للتقدم. ولو التغيير structural تقيل: gh-ost / pt-osc أو RDS Blue/Green.

</details>

<details><summary>مين يشغّل الـ migrations في ECS / Kubernetes؟ وليه مش الـ container عند الـ boot؟</summary>

خطوة واحدة متحكم فيها قبل ما الكود الجديد ياخد traffic: ECS one-off task (`run-task`) في الـ pipeline، أو Kubernetes Job / Helm `pre-upgrade` hook. عند الـ boot = N replicas بيتسابقوا، وكل restart بيحاول migrate، والفشل بيبقى CrashLoop بدل pipeline failure واضح. `--isolated` بيقلل السباق بس محتاج shared cache lock.

</details>

<details><summary>الـ migration دي هتشتغل INSTANT ولا هتعمل copy للجدول؟ إزاي تتأكد قبل الـ production؟</summary>

أجرّبها على staging بحجم داتا قريب، وأكتب `ALGORITHM=INSTANT` (أو `INPLACE, LOCK=NONE`) صريح في الـ `ALTER` عشان MySQL يرفض لو مش هيقدر بدل ما يعمل COPY بصمت. وأراجع جدول الـ online DDL operations بتاع النسخة (8.4) — مثلاً `NULL → NOT NULL` بيعمل rebuild (INPLACE مش INSTANT).

</details>

<details><summary>تغيير enum values في تطبيق Laravel بيعمل cast للـ enum — إيه الخطة؟</summary>

الـ enum cast بيستخدم `from()` فأي قيمة مش معروفة = `ValueError`. فالخطة: release فيه enum superset (القديم + الجديد) والكود بيكتب الجديد → backfill للقديم → تحقق إن مفيش قيم قديمة → release يشيل القديم. نفس اللي كان المفروض يحصل في `replace_grade_sections_with_tracks`.

</details>

## 13) Checklist — لكل PR فيه migration

- [ ] الـ migration **expand بس** (مفيش drop/rename/NOT NULL من غير default/شيل enum value) — أو ده contract release والـ expand اتعمله rollout قبله
- [ ] الكود القديم (N-1) شغال على الـ schema الجديد؛ والكود الجديد بيتحمل الـ schema القديم لو الـ migration اتأخرت
- [ ] الـ backfill منفصل، batches، idempotent، و commit لكل batch
- [ ] جرّبت `migrate --pretend` وعارف الـ algorithm (INSTANT/INPLACE/COPY) و `lock_wait_timeout` متظبط للـ ALTERs الحساسة
- [ ] مفيش اعتماد على الـ `down()` في الـ production — خطة roll-forward + snapshot قبل الـ contract
- [ ] الـ migration بتجري مرة واحدة (`migrate --force` في خطوة الـ release، مش عند الـ boot)
- [ ] اتجربت على MySQL (مش SQLite بس) — الـ CI بيعمل الاتنين
- [ ] جرّبت تمرين §6.2 والـ MDL pile-up
