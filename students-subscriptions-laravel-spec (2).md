# مشروع: نظام إدارة الطلاب والاشتراكات (Laravel)

> ملف المتطلبات ده موجّه لـ AI Agent ينفّذ المشروع كامل.
> **التقنية:** Laravel 11 أو 12 أو 13 (PHP 8.2+)، MySQL/SQLite، واجهة عربية RTL.
> **المبدأ:** بسيط، سريع، مريح. النظام لإدارة الطلاب والاشتراكات **فقط**. كل الحسابات تلقائية.

---

## 1) الفكرة في سطرين

مدرّس/مركز بيدير طلابه واشتراكاتهم الشهرية. كل اشتراك **30 يوم**. النظام بيحسب موعد التجديد القادم والحالة (فعال / قرب يخلص / منتهي) تلقائيًا من **آخر تاريخ اشتراك أو تجديد**، وبينبّه قبل التجديد بيوم، وبيحتفظ بكل تواريخ التجديد القديمة.

**نقطة مهمة:** المشروع **Multi-user**. كل مستخدم (User) يسجّل دخول ويشوف **بياناته هو بس**. مفيش أي مستخدم يقدر يشوف أو يعدّل بيانات مستخدم تاني.

---

## 2) قواعد العمل (Business Rules) — أهم جزء

### 2.1 مدة الاشتراك
- ثابتة **30 يوم** (اجعلها constant/config: `config/subscriptions.php` → `period_days = 30`).
- `next_renewal_date = last_subscription_date + 30 days`

### 2.2 أمثلة لازم تنجح (تتحوّل لـ Unit Tests)

| آخر تاريخ اشتراك/تجديد | التجديد القادم |
|---|---|
| 2026-10-01 | 2026-10-31 |
| 2026-10-31 | 2026-11-30 |
| 2026-11-30 | 2026-12-30 |

### 2.3 آخر تاريخ = التاريخ الفعال
- `last_subscription_date` = أحدث تاريخ في سجل الاشتراكات للطالب (اشتراك أولي أو تجديد).
- كل مرة يتسجّل تجديد جديد: يُضاف سجل جديد، **ولا يُحذف أو يُعدَّل أي سجل قديم**.

### 2.4 حالة الطالب (تُحسب دائمًا من تاريخ اليوم — لا تُخزَّن)

نفرض `today` بتوقيت `Africa/Cairo`، والمقارنة بالتاريخ فقط (بدون وقت):

| الشرط | الحالة | اللون |
|---|---|---|
| `today < next_renewal - 1 day` | اشتراك فعال | 🟢 |
| `today == next_renewal - 1 day` | التجديد غدًا | 🟡 |
| `today == next_renewal` | التجديد اليوم | 🟠 |
| `today > next_renewal` | الاشتراك منتهي | 🔴 |

> قرار مُتّخذ: اليوم نفسه (موعد التجديد) يُعتبر "تجديد اليوم" وليس منتهي. المنتهي يبدأ من اليوم التالي. اجعل ده في مكان واحد (Enum + method) عشان يتعدّل بسهولة لو العميل عايز غير كده.

### 2.5 عند التجديد
- المستخدم بيدخل **تاريخ التجديد فقط** (الافتراضي في الحقل: تاريخ اليوم، ويقدر يغيّره).
- بعد الحفظ: التاريخ الجديد يصبح `last_subscription_date`، يتحسب `next_renewal_date` جديد (+30)، الطالب يختفي من المنتهين/التنبيهات، ويرجع يظهر في التنبيهات قبل الموعد الجديد بيوم.
- **Validation:** تاريخ التجديد لازم يكون **بعد** آخر تاريخ مسجّل (أو نفس اليوم لا يُقبل لتفادي التكرار). لو فيه تجديد بنفس التاريخ بالفعل → رفض برسالة واضحة.

### 2.6 ترقيم الطلاب
- `number` تسلسلي **لكل مستخدم على حدة**: 1، 2، 3...
- يتولّد تلقائيًا (`max(number) + 1` لنفس الـ user داخل Transaction مع lock).
- **لا يُعاد استخدام الرقم** حتى لو طالب اتحذف (استخدم SoftDeletes).
- القائمة بتترتب افتراضيًا بـ `number`.

### 2.7 الكود
- `code` فريد **داخل نفس المستخدم** (`unique(user_id, code)`).

---

## 3) قاعدة البيانات

### `users`
الجدول الافتراضي من Laravel (name, email, password). (تسجيل الدخول + إنشاء حساب.)
يُضاف عمود `notified_on` (date, nullable) لمنع تكرار الإشعار اليومي (انظر القسم 7).

### `students`
| العمود | النوع | ملاحظات |
|---|---|---|
| id | bigint PK | |
| user_id | FK → users | `cascadeOnDelete`، index |
| number | unsignedInteger | تسلسلي لكل user |
| name | string | required |
| phone | string(20) | required |
| code | string(50) | required |
| section | string(100) | "الشعبة" required |
| notes | text nullable | النبذة / الملاحظات |
| first_subscription_date | date | تاريخ الاشتراك الأول |
| last_subscription_date | date | **denormalized** — آخر اشتراك/تجديد |
| next_renewal_date | date | **denormalized** — = last + 30 |
| deleted_at | timestamp nullable | SoftDeletes |
| timestamps | | |

Indexes / Constraints:
- `unique(user_id, number)`
- `unique(user_id, code)` (مع مراعاة SoftDeletes: لو طالب محذوف يمكن إعادة استخدام الكود — قرّر وطبّق بوضوح، الأسهل: unique عادي ومنع الحذف النهائي)
- `index(user_id, next_renewal_date)` لتسريع التنبيهات والمنتهين
- `index(user_id, name)`, `index(user_id, phone)` للبحث

> ليه denormalized؟ عشان نفلتر ونرتب ونجيب "التنبيهات" و"المنتهين" بـ query واحدة سريعة. والمصدر الحقيقي يفضل جدول `subscriptions`، والأعمدة دي بتتحدّث فقط من `SubscriptionService`.

### `subscriptions` (سجل الاشتراكات والتجديدات)
| العمود | النوع | ملاحظات |
|---|---|---|
| id | bigint PK | |
| student_id | FK → students | cascade |
| user_id | FK → users | للعزل والتقارير |
| type | enum(`initial`,`renewal`) | |
| start_date | date | تاريخ الاشتراك/التجديد |
| ends_on | date | = start_date + 30 |
| amount | decimal(10,2) nullable | اختياري — للتقارير المالية (المرحلة 2) |
| note | string nullable | |
| timestamps | | |

- `unique(student_id, start_date)`
- **ممنوع الحذف والتعديل** من الواجهة (append-only). لا يوجد route لـ update/destroy.

### `notifications`
جدول Laravel الافتراضي للـ database notifications (`php artisan notifications:table`).

### (اختياري — المرحلة 2) `message_templates`
| user_id | key | body |
لقوالب رسائل واتساب قابلة للتعديل.

---

## 4) الهيكل البرمجي المقترح

```
app/
  Enums/SubscriptionStatus.php        // Active, DueTomorrow, DueToday, Expired  (+ label(), color(), emoji())
  Models/{Student,Subscription}.php
  Services/SubscriptionService.php    // addStudent(), renew()
  Policies/StudentPolicy.php
  Http/Controllers/{DashboardController,StudentController,RenewalController,NotificationController,ReportController}.php
  Http/Requests/{StoreStudentRequest,UpdateStudentRequest,RenewStudentRequest}.php
  Services/NotificationSyncService.php   // مزامنة الإشعارات عند فتح الشاشة (بدون cron)
  Notifications/RenewalDueNotification.php
config/subscriptions.php
```

### Enum
```php
enum SubscriptionStatus: string {
    case Active = 'active';
    case DueTomorrow = 'due_tomorrow';
    case DueToday = 'due_today';
    case Expired = 'expired';
    // label() عربي, emoji() 🟢🟡🟠🔴, color() لكلاسات Tailwind
}
```

### Student model (أهم الأجزاء)
```php
protected $casts = [
  'first_subscription_date' => 'date',
  'last_subscription_date'  => 'date',
  'next_renewal_date'       => 'date',
];

public function status(?Carbon $today = null): SubscriptionStatus {
    $today = ($today ?? now('Africa/Cairo'))->startOfDay();
    $due   = $this->next_renewal_date->copy()->startOfDay();
    return match (true) {
        $today->gt($due)                   => SubscriptionStatus::Expired,
        $today->eq($due)                   => SubscriptionStatus::DueToday,
        $today->eq($due->copy()->subDay()) => SubscriptionStatus::DueTomorrow,
        default                            => SubscriptionStatus::Active,
    };
}

// Global scope: where user_id = auth()->id()  (أو Trait BelongsToUser)
// Scopes: dueTomorrow(), dueToday(), expired(), active(), search($term)
```

### SubscriptionService (داخل DB::transaction)
```php
addStudent(User $user, array $data): Student
  // 1) يولّد number  2) ينشئ student
  // 3) ينشئ subscription type=initial  4) يضبط first/last/next

renew(Student $student, Carbon $date): Subscription
  // 1) validation: $date > last_subscription_date
  // 2) ينشئ subscription type=renewal
  // 3) يحدّث last_subscription_date = $date, next_renewal_date = $date + 30
```
> أي كود تاني **ممنوع** يكتب في الأعمدة دي مباشرة.

---

## 5) عزل بيانات المستخدمين (Multi-user) — إلزامي

- كل Model فيه `user_id` يستخدم Trait `BelongsToUser` فيه **Global Scope** + `creating` hook يملأ `user_id` تلقائيًا.
- `StudentPolicy` (view/update/renew) يتحقق إن `student->user_id === auth()->id()`.
- Route Model Binding لازم يرجّع 404 لو الطالب مش بتاع المستخدم.
- **Feature Test إلزامي:** مستخدم B مينفعش يفتح/يعدّل/يجدّد طالب تابع لمستخدم A (نتوقع 404/403)، ومينفعش يظهر في القوائم أو البحث أو التقارير.

---

## 6) الصفحات (Blade + Tailwind RTL + Alpine.js، أو Livewire — الأبسط)

نظام الدخول: **Laravel Breeze** (Blade). اللغة الافتراضية عربي، `dir="rtl"`، خط Cairo أو Tajawal.

### 6.1 الرئيسية — قائمة الطلاب `/students`
- زرار **➕ إضافة طالب** بارز.
- بحث واحد (live أو submit) بالـ **الكود** أو **الاسم** أو **رقم الهاتف**.
- فلتر سريع بالحالة: الكل / فعال / غدًا / اليوم / منتهي. (Tabs مع عدّادات)
- جدول:

`رقم | الاسم | الكود | الهاتف | الشعبة | آخر اشتراك | التجديد القادم | الحالة`

- الحالة badge ملوّن (🟢🟡🟠🔴). الصف المنتهي بخلفية حمراء خفيفة.
- الترتيب الافتراضي بـ `number`. Pagination (25 في الصفحة).
- الضغط على الصف يفتح صفحة الطالب.

### 6.2 إضافة طالب `/students/create`
الحقول: الاسم*، الهاتف*، الكود*، الشعبة*، تاريخ الاشتراك* (الافتراضي اليوم)، النبذة (اختياري).
- يعرض تحت حقل التاريخ معاينة فورية: **"التجديد القادم: 31/10/2026"** (JS بسيط).
- بعد الحفظ → صفحة الطالب.

### 6.3 صفحة الطالب `/students/{student}`
- بيانات الطالب + النبذة (وزر تعديل البيانات — ماعدا التواريخ).
- كارت الحالة: الحالة الحالية، آخر اشتراك/تجديد، التجديد القادم، **وعدد الأيام المتبقية/المتأخرة**.
- **زرار "تسجيل تجديد"** (Modal فيه حقل تاريخ فقط، الافتراضي اليوم).
- **زرار "📱 إرسال رسالة واتساب"** (انظر القسم 8).
- **سجل الاشتراكات والتجديدات:** جدول بكل التواريخ (أحدث فوق)، مع النوع (اشتراك/تجديد) وتاريخ انتهاء كل فترة. للقراءة فقط.

### 6.4 الإشعارات / التجديدات `/notifications`
قسم بيتحسب لايف من الداتا (مش لازم يعتمد على الـ job):

- 🔴 **منتهي** (مرتّب بالأقدم انتهاءً)
- 🟠 **تجديد اليوم**
- 🟡 **تجديد غدًا**

كل سطر: `الاسم — كود 123456` + أزرار: فتح الطالب | واتساب | تسجيل تجديد سريع.

### 6.5 Dashboard صغير (اختياري لكن مفيد) `/dashboard`
4 كروت أرقام: إجمالي الطلاب، فعال، غدًا/اليوم، منتهي. + رابط للإشعارات.

---

## 7) الإشعارات الداخلية (In-app)

1. **أيقونة جرس 🔔** في الـ navbar بعدّاد = `عدد (غدًا + اليوم + منتهي)` محسوب من الـ DB مباشرة. الضغط عليها → `/notifications`.
2. **Laravel Database Notifications** (اختياري كطبقة إضافية) — **بدون Cron ولا Queue ولا Job**:
   - المزامنة بتتم **عند فتح الشاشة الأولى بعد تسجيل الدخول** (أول زيارة لـ `/students` أو `/dashboard` في اليوم).
   - `NotificationSyncService::syncFor(User $user)`:
     1. لو `users.notified_on == today` → لا يعمل شيء (يرجع فورًا، بدون أي query تقيلة).
     2. غير كده: يجيب طلاب المستخدم اللي تجديدهم **غدًا**، ولو فيه → يبعت notification واحدة مجمّعة ("3 طلاب تجديدهم غدًا").
     3. يحدّث `users.notified_on = today`.
   - يتنادى من Middleware خفيف `SyncNotifications` على مسارات الشاشة الرئيسية فقط (أو من الـ Controller مباشرة).
   - **منع التكرار:** عمود `notified_on` (date, nullable) في جدول `users` (ضيفه في migration). ممكن بديله Cache key `notified:{user_id}:{Y-m-d}`.
   - التنفيذ sync وسريع لأنه query واحدة على index `(user_id, next_renewal_date)`.
3. الإشعار بيتعلّم "مقروء" لما المستخدم يفتح صفحة الإشعارات.

> الأساس إن **القائمة الحية** (الحالات والعدّاد والـ `/notifications`) بتتحسب من الـ DB عند كل طلب، فمش محتاجة أي مزامنة. الـ notifications table مجرد سجل إضافي، والنظام يشتغل صح حتى لو اتلغت المزامنة تمامًا.
> **لا تستخدم** `Schedule` أو `queue:work` أو أي Cron في المشروع ده.

---

## 8) رسائل واتساب (بدون API — بسيط ومجاني)

بدل ما نربط WhatsApp Business API (معقّد ومدفوع)، نستخدم رابط `wa.me` يفتح واتساب بالرسالة جاهزة والمستخدم يضغط إرسال:

```
https://wa.me/{phone_international}?text={urlencoded_message}
```

- دالة `Student::whatsappUrl(string $template): string`:
  - تنضّف الرقم (شيل المسافات والرموز).
  - تحوّل الرقم المصري من `01xxxxxxxxx` إلى `201xxxxxxxxx` (شيل الصفر الأول وحط `20`). اجعل كود الدولة الافتراضي في config: `default_country_code = 20`.
  - لو الرقم بيبدأ بـ `+` أو `00` اتعامل معاه كدولي.
- قالب الرسالة الافتراضي (قابل للتعديل من صفحة إعدادات بسيطة في المرحلة 2):

```
أهلاً {name} 👋
بنفكّرك إن اشتراكك (كود {code}) بيتجدد بتاريخ {next_renewal_date}.
برجاء التجديد لضمان استمرار الحضور. شكرًا 🌷
```

- متغيرات: `{name}` `{code}` `{section}` `{next_renewal_date}` `{days_left}`.
- قالب مختلف للمنتهي: "اشتراكك انتهى بتاريخ {next_renewal_date}، برجاء التجديد...".
- زرار الواتساب يظهر في: صفحة الطالب + قائمة الإشعارات.

> **ترقية مستقبلية:** الإرسال التلقائي عبر WhatsApp Cloud API أو Twilio — اتركه خارج النطاق الحالي، لكن خلّي الـ logic في `WhatsAppLinkBuilder` منفصل عشان يتبدّل بسهولة.

---

## 9) التقارير (المرحلة 2 — بسيطة)

صفحة `/reports` بفلتر شهر/فترة:
- عدد الطلاب الجدد في الفترة.
- عدد التجديدات في الفترة.
- عدد المنتهين حاليًا + قائمتهم.
- **نسبة التجديد:** (من كان موعد تجديده في الفترة وجدّد) ÷ (إجمالي من موعده في الفترة).
- توزيع الطلاب حسب **الشعبة** (وعدد الفعال/المنتهي في كل شعبة).
- (لو اتضاف `amount`) إجمالي الإيراد الشهري.
- زرار **تصدير CSV/Excel** للقائمة والتقارير (`maatwebsite/excel` أو CSV بسيط بـ `streamDownload`).

---

## 10) قواعد جودة وتجربة استخدام

- كل النصوص بالعربي في ملفات `lang/ar` (مش hardcoded).
- تنسيق التاريخ المعروض: `d/m/Y`. التخزين: `Y-m-d`. اللغة في Carbon: `ar`.
- أرقام الهاتف: تُخزَّن كما أُدخلت بعد تنظيف المسافات، ويُحسب الرابط الدولي وقت العرض.
- رسائل Validation بالعربي وواضحة.
- تأكيد قبل أي عملية حساسة (حذف طالب = Soft Delete مع تأكيد).
- Mobile-friendly (المستخدم غالبًا هيفتح من الموبايل): الجدول يتحوّل لكروت على الشاشات الصغيرة.
- لا Over-engineering: مفيش API، مفيش SPA، مفيش roles معقدة.

---

## 10.1) UI / UX (إلزامي — مش اختياري)

### الاتجاه البصري
- تصميم **نظيف وهادي** بمساحات بيضاء كافية، بدون زحمة. خلفية رمادي فاتح جدًا، كروت بيضاء بحواف مدوّرة (`rounded-xl`) وظل خفيف.
- لون أساسي واحد (مثلًا Indigo/Teal) + ألوان الحالات فقط (أخضر/أصفر/برتقالي/أحمر). لا تستخدم ألوان زيادة.
- خط **Cairo** أو **Tajawal** (Google Fonts)، أحجام واضحة، وتباين ألوان كافي (WCAG AA).
- أيقونات متناسقة من مكتبة واحدة (Heroicons أو Lucide).
- **Dark mode** اختياري (`prefers-color-scheme`) — لو هيعطّل التنفيذ، أجّله.
- `dir="rtl"` على مستوى الصفحة، واستخدم خصائص logical في Tailwind (`ms-*`, `me-*`, `ps-*`, `pe-*`, `text-start`) بدل `ml/mr` عشان الـ RTL يطلع صح.

### Loader على الأزرار (منع الضغط المتكرر)

**القاعدة:** أي زرار بيعمل إرسال (Submit) أو طلب للسيرفر لازم يكون عليه **Loader** ويتعطّل بمجرد الضغط، عشان مفيش عملية تتسجل مرتين (إضافة طالب، تسجيل تجديد، تعديل، تسجيل دخول، تصدير).

1. **Blade Component موحّد** `<x-button>` (أو `<x-submit-button>`) بدل تكرار الكود:
   - props: `type`, `variant` (primary/secondary/danger), `loadingText` (افتراضي: "جاري الحفظ...").
   - أثناء التحميل: يظهر **Spinner** صغير جنب النص، النص يتغيّر لـ `loadingText`، الزرار `disabled`، و`cursor-not-allowed`، و`opacity-70`.
   - **يحافظ على نفس العرض** أثناء التحميل (عشان الشكل ميتهزّش).
2. **التنفيذ بـ Alpine.js** (الأبسط):
   ```blade
   <form x-data="{ loading: false }" @submit="loading = true" method="POST" ...>
     @csrf
     <button type="submit" :disabled="loading" class="...">
       <svg x-show="loading" class="animate-spin h-4 w-4" ...></svg>
       <span x-text="loading ? 'جاري الحفظ...' : 'حفظ'"></span>
     </button>
   </form>
   ```
3. **ملاحظات مهمة:**
   - الـ loader يتفعّل على حدث `submit` للـ form (مش على `click`) عشان لو الـ validation في المتصفح فشل ميفضلش الزرار معلّق.
   - لو الصفحة رجعت بأخطاء Validation، الزرار يرجع لحالته الطبيعية (الصفحة بتتعمل reload فالـ state بيتصفّر تلقائيًا). ولو استخدمت `bfcache`/زرار الرجوع، أضف `pageshow` listener يرجّع `loading = false`.
   - **Enter في الـ input** لازم يمر بنفس الحماية (لأنه بيشغّل `submit`).
   - لو استخدمت Livewire بدل Blade: استخدم `wire:loading.attr="disabled"` و`wire:loading` و`wire:target`.
   - أي طلب AJAX (fetch): عطّل الزرار قبل الطلب وفعّله في `finally`.
   - زراير الروابط اللي بتعمل طلب (مثل تصدير) تاخد نفس الـ loader.

### حماية الـ Backend ضد الإرسال المزدوج (لا تعتمد على الـ UI فقط)
- `unique(student_id, start_date)` على `subscriptions` (موجود) + التعامل مع الخطأ برسالة عربية لطيفة ("التجديد ده متسجّل بالفعل").
- `unique(user_id, code)` و`unique(user_id, number)` على `students`.
- كل عمليات الكتابة داخل `DB::transaction` مع `lockForUpdate()` عند توليد `number`.
- **Idempotency اختياري:** حقل hidden `submission_token` (UUID) يتولّد مع الفورم، ويتخزّن في Cache لدقيقة؛ لو اتبعت تاني بنفس الـ token يتجاهل الطلب ويرجع لنفس النتيجة.
- اعتمد نمط **Post/Redirect/Get** بعد أي حفظ (عشان الريفريش ميعيدش الإرسال).

### تجربة الاستخدام (UX)
- **Feedback فوري:** Toast/Alert في أعلى الصفحة بعد كل عملية ("تمت إضافة الطالب ✅"، "تم تسجيل التجديد ✅") يختفي تلقائيًا بعد 4 ثواني، ومعاه زرار إغلاق.
- **Validation:** رسائل خطأ بالعربي تحت كل حقل بلون أحمر هادي، والحقول بتفضل محتفظة بالقيم المدخلة (`old()`)، والـ focus ينتقل لأول حقل فيه خطأ.
- **Modal التجديد:** يفتح فوق الصفحة (بدون تنقل)، الحقل فيه تاريخ اليوم جاهز، والـ focus تلقائي عليه، ويعرض معاينة: "التجديد القادم: 30/11/2026"، و`Esc` يقفله.
- **معاينة التاريخ الفوري** في إضافة طالب (موجودة في القسم 6.2).
- **البحث:** `debounce` 300ms، زرار مسح (✕) داخل الحقل، ويحافظ على الفلتر والصفحة في الـ URL (`?q=...&status=...`). لو مفيش نتائج: "مفيش نتائج للبحث عن «...»" مع اقتراح.
- **Empty states:** لو مفيش طلاب: رسالة ودودة + زرار "➕ أضف أول طالب". نفس الفكرة في الإشعارات ("كله تمام، مفيش تجديدات قريبة 🎉").
- **Skeleton/Loading** خفيف للجداول الكبيرة لو اتحمّلت بـ AJAX.
- **تأكيد العمليات الحساسة** (حذف طالب) بـ Modal مخصّص بدل `confirm()` الافتراضي للمتصفح، وزرار التأكيد عليه loader برضو.
- **Badge الحالة:** لون + أيقونة + نص (مش لون بس)، عشان واضح لمن لا يميّز الألوان.
- **الأرقام والتواريخ:** عرض `d/m/Y`، والأرقام إنجليزي (0-9) لسهولة نسخ الهاتف والكود.
- **زرار الواتساب:** أخضر بأيقونة واتساب، يفتح في تبويب جديد (`target="_blank" rel="noopener"`).
- **Sticky header** للجدول على الشاشات الكبيرة، و**Sticky action bar** (زرار إضافة) على الموبايل.

### Responsive / Mobile-first
- الموبايل أولًا: الجدول يتحوّل لـ **كروت** (اسم + كود + حالة + التجديد القادم + أزرار سريعة).
- مساحة الضغط للأزرار **لا تقل عن 44×44px**.
- Navbar مبسّط: الشعار + الجرس 🔔 (بعدّاد) + قائمة المستخدم. على الموبايل: bottom navigation (الطلاب / الإشعارات / التقارير).
- اختبر على عرض 360px.

### Accessibility
- كل `input` له `label` مربوط.
- `aria-busy="true"` و`aria-live="polite"` على الزرار/رسائل الحالة أثناء التحميل.
- Focus ring واضح، وتنقّل كامل بالكيبورد، والـ Modal يحبس الـ focus (focus trap) ويرجّعه عند الإغلاق.

### الأداء
- Vite لتجميع الأصول، لا مكتبات تقيلة (Tailwind + Alpine كفاية).
- Eager loading لأي علاقات (`with()`) لتفادي N+1.
- Pagination بدل تحميل كل الطلاب.

---

## 11) الاختبارات (Pest أو PHPUnit)

**Unit**
- حساب `next_renewal_date` للأمثلة في 2.2 (وحالة الانتقال بين الشهور والسنة الكبيسة).
- `Student::status()` لكل الحالات الأربع (استخدم `Carbon::setTestNow`).

**Feature**
- إضافة طالب → يتولّد `number` صحيح، وinitial subscription، وnext_renewal صح.
- أرقام الطلاب تسلسلية لكل مستخدم بشكل مستقل (مستخدمين مختلفين يبدأ كل واحد من 1).
- تجديد → ينشأ سجل، آخر تاريخ يتحدّث، التاريخ القديم يفضل موجود، والحالة ترجع فعال.
- رفض تجديد بتاريخ أقدم/مكرر.
- عزل المستخدمين (القسم 5).
- البحث بالكود/الاسم/الهاتف.
- `NotificationSyncService`: يبعت notification للمستخدم الصح فقط عند أول فتح للشاشة في اليوم، ومفيش تكرار لو فتح الشاشة تاني في نفس اليوم، ويشتغل تاني تلقائيًا في اليوم التالي.
- رابط واتساب: تحويل `01012345678` → `201012345678`.
- **الإرسال المزدوج:** إرسال نفس طلب التجديد مرتين متتاليتين ينتج سجل واحد فقط ورسالة مفهومة في الثانية، وإرسال نفس نموذج إضافة طالب مرتين لا ينتج طالبين بنفس الكود.

---

## 12) خطة التنفيذ (مراحل)

**المرحلة 1 — MVP (المطلوب الأساسي)**
1. Laravel + Breeze + Tailwind RTL + لغة عربية + timezone `Africa/Cairo`.
2. Migrations + Models + Enum + `SubscriptionService` + Trait العزل + Policy.
3. قائمة الطلاب (بحث + فلتر + ترتيب بالرقم) + إضافة + صفحة الطالب + تسجيل تجديد + السجل.
4. صفحة الإشعارات + جرس بعدّاد + رابط واتساب.
5. Database notifications عبر `NotificationSyncService` عند فتح الشاشة (بدون cron/queue).
6. Seeder تجريبي (مستخدمين + 30 طالب بحالات مختلفة) + الاختبارات.

**المرحلة 2 — تحسينات**
- Dashboard، التقارير والتصدير، قوالب رسائل قابلة للتعديل، حقل المبلغ.

**المرحلة 3 — اختياري**
- إرسال واتساب تلقائي بـ API، Backup، استيراد طلاب من Excel.

---

## 13) معايير القبول (Definition of Done)

- [ ] إضافة طالب بتاريخ 1/10/2026 تعرض التجديد القادم 31/10/2026 تلقائيًا.
- [ ] تسجيل تجديد يوم 31/10 يعرض التالي 30/11 ثم 30/12.
- [ ] الطالب يظهر في الإشعارات قبل الموعد بيوم، ويظهر 🔴 بعد الموعد.
- [ ] بعد التجديد الحالة تتحدث فورًا ويختفي من المنتهين.
- [ ] كل التواريخ القديمة محفوظة وظاهرة في سجل الطالب ولا يمكن حذفها.
- [ ] كل مستخدم يرى بياناته فقط (مُختبر).
- [ ] الترقيم تسلسلي لكل مستخدم والبحث بالكود/الاسم/الهاتف شغال.
- [ ] زرار واتساب يفتح الرسالة جاهزة برقم صحيح.
- [ ] الواجهة عربية RTL وتعمل بشكل مريح على الموبايل (الجدول يتحوّل لكروت، وأزرار 44px+).
- [ ] **كل زرار إرسال عليه Loader ويتعطّل فور الضغط** (إضافة، تجديد، تعديل، دخول، تصدير)، والضغط السريع المتكرر لا يُنتج سجلات مكررة.
- [ ] رسائل نجاح/خطأ واضحة (Toast) وEmpty states في كل القوائم.
- [ ] Modal التجديد يعرض معاينة التاريخ القادم ويُغلق بـ Esc.
- [ ] كل الاختبارات تنجح.

---

## 14) أسئلة مفتوحة للعميل (التنفيذ يكمل بالافتراضات المكتوبة لحد ما يرد)

1. لو الطالب جدد **متأخر** (مثلًا موعده 31/10 وجدد يوم 5/11) — التجديد الجديد يُحسب من **5/11** (الافتراضي الحالي، لأن العميل قال "آخر تاريخ مسجّل") ولا من 31/10 (استمرارية الدورة)؟
2. "تجديد اليوم" يُعتبر 🟠 مش منتهي — مناسب؟
3. هل مطلوب تسجيل **المبلغ المدفوع** مع كل تجديد؟
4. هل مطلوب تنبيه إضافي يوم الموعد أو بعده (مش بس قبلها بيوم)؟
5. كود الدولة الافتراضي للواتساب: مصر (+20)؟
