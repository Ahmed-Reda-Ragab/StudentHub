# 83 — Edge security (WAF، HTTPS، headers، rate limiting)

> **الهدف في سطر:** تحط HTTPS حقيقي على الـ ALB (ACM + redirect من HTTP)، تفهم ليه Laravel محتاج `trustProxies` + `X-Forwarded-Proto`، تضيف security headers من الـ ALB، تحمي الـ edge بـ AWS WAF (managed rule groups + rate-based rule) من الـ Console ومن Terraform، وتقفل `/metrics` و `/sre-lab/*` من برّه — وتعرف Shield Standard بيعمل إيه.
> **المستوى:** Intermediate → Advanced · **الوقت:** ~3 ساعات · **التكلفة التقريبية:** ~$6/شهر (WAF) + Route 53 hosted zone ($0.50) + الـ ALB
> **بيعتمد على:** [42](42-alb-asg-launch-template.md) أو [51](51-ecs-fargate-terraform.md) · [80](80-iam-oidc-least-privilege.md) · **الملفات في الـ repo:** [`modules/alb/main.tf`](../../../infra/terraform/modules/alb/main.tf) · [`modules/alb/variables.tf`](../../../infra/terraform/modules/alb/variables.tf) · [`stacks/40-ec2-alb-asg/dns.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/dns.tf) · [`stacks/50-ecs-fargate/variables.tf`](../../../infra/terraform/stacks/50-ecs-fargate/variables.tf) · [`bootstrap/app.php`](../../../bootstrap/app.php) · [`EnsureSreLabEnabled.php`](../../../app/Http/Middleware/EnsureSreLabEnabled.php) · [`MetricsController.php`](../../../app/Http/Controllers/MetricsController.php) · [`config/session.php`](../../../config/session.php)

## 1) الفكرة (Concepts)

الـ edge = أول نقطة الـ traffic بيلمسها (هنا الـ ALB). أي حاجة تقدر توقفها هناك أرخص وأأمن من إنك توقفها في PHP: TLS، redirects، paths ممنوعة، bots، brute force، و L3/L4 DDoS.

| المصطلح | المعنى |
|---|---|
| TLS termination | الـ ALB بيفك الـ TLS؛ الـ traffic للـ targets HTTP جوه الـ VPC |
| ACM | شهادات public مجانية بـ renewal أوتوماتيك (DNS validation) |
| Security policy | الـ TLS versions/ciphers المسموحة على الـ listener (`ELBSecurityPolicy-TLS13-1-2-2021-06` = TLS 1.3 + 1.2) |
| `X-Forwarded-Proto` / `X-Forwarded-For` | headers الـ ALB بيحطها: الـ client كان https؟ IP بتاعه إيه؟ |
| HSTS | `Strict-Transport-Security`: المتصفح يرفض http للدومين ده لمدة `max-age` |
| AWS WAF | L7 firewall على الـ ALB/CloudFront/API Gateway: web ACL (في الـ console الجديد اسمها **protection pack**) = rules بترتيب priority |
| Managed rule group | rules جاهزة من AWS (Core rule set، Known bad inputs، SQLi، PHP، IP reputation...) |
| Rate-based rule | block/count لما IP (أو aggregate key) يعدّي N request في window |
| WCU | Web ACL Capacity Units — كل rule ليها تكلفة، والـ web ACL ليه حد (1,500 افتراضياً قبل تسعير إضافي) |
| Shield Standard | حماية L3/L4 DDoS أوتوماتيك ومجانية على ALB/CloudFront/Route 53 |

## 2) المعمارية (Architecture)

```text
 client ──► Route 53 (alias A → ALB, evaluate_target_health) ──► Shield Standard (L3/L4، أوتوماتيك)
                                                                  │
                         ┌────────────────── ALB student-app-lab-alb ──────────────────────────┐
                         │ :80  HTTP  → redirect 301 → :443   (لما فيه certificate)             │
 AWS WAF web ACL ───────►│ :443 HTTPS (ACM cert، TLS13-1-2-2021-06)                             │
 (managed rules +        │   rule priority 1: /metrics, /metrics/* → fixed 404  (alb module)    │
  rate limit +           │   [مقترح] /sre-lab/* → 404 (أو WAF)                                  │
  block /sre-lab)        │   default: weighted forward → TG blue / TG green (health /ready)     │
                         │   [مقترح] response headers: HSTS, X-Content-Type-Options, X-Frame…   │
                         └───────────────────────────────┬──────────────────────────────────────┘
                                   X-Forwarded-Proto: https · X-Forwarded-For: <client>
                                                         ▼
 container nginx (real_ip، TRUSTED_PROXY=local) ──► Laravel trustProxies(at: '*', X-Forwarded-Proto)
   → url()/redirects بـ https://   · SESSION_SECURE_COOKIE=true → cookie بـ Secure
   → /sre-lab/*: EnsureSreLabEnabled (404 لو مقفول، 403 من غير X-Lab-Token)  · /metrics: METRICS_TOKEN اختياري
```

## 3) المتطلبات (Prerequisites)

- [ ] stack 40 أو 50 شغال (ALB موجود).
- [ ] دومين وعندك hosted zone في Route 53 (`hosted_zone_id`) — أو أي DNS provider تقدر تضيف فيه CNAME للـ validation. من غير دومين: جرّب الـ WAF والـ headers على HTTP بس.
- الأدوات: `aws`، `terraform`، `curl`، `openssl`.

## 4) الطريقة الأولى: AWS Console (يدوي)

### 4.1 شهادة ACM

1. **Certificate Manager → Request → Request a public certificate** → Domain `lab.<YOUR_DOMAIN>` → **DNS validation** → Request.
2. افتح الـ cert → **Create records in Route 53** → Create. استنى **Issued** (دقايق). الـ cert لازم يبقى في **نفس region الـ ALB** (`us-east-1`).

### 4.2 HTTPS listener + redirect

1. **EC2 → Load Balancers → `student-app-lab-alb` → Listeners and rules → Add listener**: HTTPS : 443 → Default action **Forward to target groups**: `student-app-lab-blue` (100) و `student-app-lab-green` (0) → Security policy `ELBSecurityPolicy-TLS13-1-2-2021-06` → Certificate من ACM → Add.
2. افتح الـ **HTTP:80** listener → **Edit listener** → Default action: **Redirect to URL** → HTTPS، port 443، status **301** → Save.
3. انقل الـ rule بتاعة `/metrics` (fixed 404) للـ HTTPS listener — الـ module بيحطها على الـ listener اللي شايل الـ traffic.
4. **Route 53 → Hosted zone → Create record**: `lab` → A → **Alias** → Application Load Balancer → الـ region → الـ ALB.
5. **Security group** بتاع الـ ALB: 443 مفتوح (الـ module بيفتح 80 و 443 من `ingress_cidrs`).

> ⚠️ لو الـ stack متعمل بـ Terraform، التعديلات اليدوية دي **drift** وهتتمسح مع الـ apply الجاي — اعملها في ALB يدوي، أو استخدم §5.

### 4.3 Security headers من الـ ALB

**Listener HTTPS → Attributes → Edit → Add response headers**: Strict-Transport-Security = `max-age=31536000; includeSubDomains`، X-Content-Type-Options = `nosniff`، X-Frame-Options = `SAMEORIGIN`، و **ALB server response header** → Disable (يشيل `Server: awselb/2.0`) → Save. الـ ALB بيضيف الـ header على كل response (ولو التطبيق باعته بيستبدل قيمته).

### 4.4 AWS WAF

الـ console الجديد (2025) بيسمي الـ web ACL **protection pack** وبيقترحلك pack حسب نوع التطبيق؛ الـ console القديم (standard) لسه موجود. الـ resource تحت هو نفسه WAFv2 web ACL.

1. **AWS WAF & Shield → Protection packs (web ACLs) → Create** → Resource type: **Regional resources** (`us-east-1`) → اختار/عدّل الـ pack أو ابني يدوي:
   - Name `student-app-lab-waf` → **Add AWS resources** → الـ ALB.
2. Rules (بالترتيب):
   | Priority | Rule | Action |
   |---|---|---|
   | 0 | Custom: URI path starts with `/sre-lab/` → Block (أو استثناء IP set للـ game day) | Block |
   | 1 | `AWSManagedRulesAmazonIpReputationList` | Block |
   | 2 | `AWSManagedRulesCommonRuleSet` | **Count** الأول (أسبوع) ثم Block |
   | 3 | `AWSManagedRulesKnownBadInputsRuleSet` | Block |
   | 4 | `AWSManagedRulesSQLiRuleSet` | Count → Block |
   | 5 | `AWSManagedRulesPHPRuleSet` | Count → Block |
   | 6 | Rate-based: 100 request / 5 دقايق لكل IP، scope-down: path = `/login` و method = POST | Block |
   | 7 | Rate-based عام: 2000 / 5 دقايق لكل IP | Block |
   Default action: **Allow**.
3. **Logging**: CloudWatch Logs group اسمه **لازم يبدأ بـ `aws-waf-logs-`** (مثلاً `aws-waf-logs-student-app-lab`)، retention 7 أيام. فعّل **redacted fields** لـ `authorization` و `x-lab-token` و `cookie`.
4. **Sampled requests / Overview** → شوف مين بيتعمله match.

> 💡 ليه **Count** الأول؟ الـ Common rule set فيه rules زي حدود حجم الـ body وأنماط XSS ممكن تعمل false positives على فورمز بنصوص عربي طويلة. Count أسبوع، اقرا اللوج، استثني الـ rule أو الـ path اللي بيعمل مشكلة، وبعدين Block.

## 5) الطريقة التانية: Infrastructure as Code

### 5.1 HTTPS في الـ `alb` module (موجود)

```hcl
locals {
  https          = var.https_enabled != null ? var.https_enabled : var.certificate_arn != null
  http_forwards  = local.https ? [] : [1]   # من غير cert: HTTP بيشيل الـ traffic
  http_redirects = local.https ? [1] : []   # بالـ cert: HTTP بيعمل redirect بس
}
```

- `certificate_arn` (default `null`) → HTTPS listener بـ `ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"` + HTTP listener `redirect` لـ 443 بـ `HTTP_301`.
- `https_enabled` منفصل لأن الـ ARN مش معروف وقت الـ plan (ميقدرش يحرّك `count`).
- `aws_lb_listener_rule.block_metrics` (priority 1) على `traffic_listener_arn` (الـ HTTPS لو موجود): `/metrics` و `/metrics/*` → fixed-response 404.
- `drop_invalid_header_fields = true` (headers مشوّهة/request smuggling)، الـ SG: 80/443 من `ingress_cidrs` (default `0.0.0.0/0`) و egress للـ VPC بس على الـ target port.

**Stack 40** ([`dns.tf`](../../../infra/terraform/stacks/40-ec2-alb-asg/dns.tf)): `domain_name` + `hosted_zone_id` → `aws_acm_certificate` (DNS، `create_before_destroy`) + validation records + `aws_acm_certificate_validation` + alias A record؛ و `APP_URL` في SSM بيبقى `https://<domain>`.

```bash
cd infra/terraform/stacks/40-ec2-alb-asg
terraform apply -var domain_name=lab.<YOUR_DOMAIN> -var hosted_zone_id=<ZONE_ID> -var image_tag=<SHA7>
terraform output -raw app_url
```

**Stack 50:** `-var certificate_arn=<ACM_ARN>` (و `app_url` لو عايز `APP_URL` بالـ https).

### 5.2 Laravel خلف proxy ([`bootstrap/app.php`](../../../bootstrap/app.php))

```php
// Behind ALB / nginx / ingress: TLS ends at the proxy, so trust X-Forwarded-Proto
$middleware->trustProxies(at: '*', headers: Request::HEADER_X_FORWARDED_PROTO);
```

- من غيرها: الـ request جوه PHP شكله `http://` → `url()`/`route()`/`redirect()` يطلّعوا `http://` → redirect loop مع الـ ALB redirect، mixed content، والـ CSRF/same-origin checks تتلخبط.
- `at: '*'`: يثق في أي proxy — مقبول لأن الـ SG بتاع الـ instances/tasks بيقبل من الـ ALB SG بس (محدش يقدر يوصل الـ container مباشرة ويزوّر الـ header).
- `HEADER_X_FORWARDED_PROTO` بس (مش `X-Forwarded-For`): الـ client IP بيرجّعه nginx اللي جوه الـ container (`real_ip`، `TRUSTED_PROXY=local` في الـ Dockerfile) — مهم للـ login throttle (5 محاولات لكل email+IP) واللوجز.
- **`SESSION_SECURE_COOKIE`** ([`config/session.php`](../../../config/session.php)): stack 40 بيكتبه في SSM أوتوماتيك = `tostring(local.https_enabled)` → `true` أول ما تحط `domain_name`، والـ session cookie يطلع بـ `Secure` (الـ cookie عمره ما يتبعت على HTTP). Stacks 20 و 50 **مش** بيكتبوه — لو فعّلت HTTPS على stack 50 (`certificate_arn`) ضيفه بإيدك:
  ```bash
  aws ssm put-parameter --name /student-app/lab/app/SESSION_SECURE_COOKIE --type String --value true --overwrite
  aws ecs update-service --cluster student-app-lab --service student-app-lab-app --force-new-deployment   # الـ secrets بتتقري وقت بداية الـ task
  ```
  (على stack 40 الـ parameter متملوك لـ Terraform — متعدّلوش بإيدك؛ بعد ما الـ `apply` يغيّره اعمل instance refresh.)

### 5.3 Security headers بـ Terraform (**مش في الـ repo**)

الـ listener attributes (`routing.http.response.*`) — بالـ CLI:

```bash
aws elbv2 modify-listener-attributes --listener-arn "$(terraform output -raw listener_arn)" --attributes \
  '[{"Key":"routing.http.response.strict_transport_security.header_value","Value":"max-age=31536000; includeSubDomains"},
    {"Key":"routing.http.response.x_content_type_options.header_value","Value":"nosniff"},
    {"Key":"routing.http.response.x_frame_options.header_value","Value":"SAMEORIGIN"},
    {"Key":"routing.http.response.server.enabled","Value":"false"}]'
```

وفي الـ AWS provider الـ `aws_lb_listener` عنده arguments مقابلة (زي `routing_http_response_strict_transport_security_header_value`، `routing_http_response_x_content_type_options_header_value`، `routing_http_response_x_frame_options_header_value`، `routing_http_response_server_enabled`) — اتأكد من الأسماء في docs نسخة الـ provider عندك وضيفهم للـ HTTPS listeners في الـ `alb` module. `Content-Security-Policy` محتاج ضبط مع Vite assets و الـ inline scripts قبل ما تفرضه (ابدأ بـ `Content-Security-Policy-Report-Only` من التطبيق).

> HSTS بـ `includeSubDomains` (و `preload`) قرار صعب الرجوع فيه — المتصفحات بتفتكره لمدة `max-age`. ابدأ بـ `max-age=300` وكبّره.

### 5.4 WAF بـ Terraform (**snippet تضيفه — مش موجود في الـ repo**)

ملف جديد مثلاً `infra/terraform/stacks/40-ec2-alb-asg/waf.tf`:

```hcl
resource "aws_wafv2_web_acl" "app" {
  name  = "${local.name}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # 0) /sre-lab/* never from the internet (game days: add an IP-set exception before this rule)
  rule {
    name     = "block-sre-lab"
    priority = 0
    action {
      block {}
    }
    statement {
      byte_match_statement {
        search_string         = "/sre-lab/"
        positional_constraint = "STARTS_WITH"
        field_to_match {
          uri_path {}
        }
        text_transformation {
          priority = 0
          type     = "LOWERCASE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "block-sre-lab"
      sampled_requests_enabled   = true
    }
  }

  # 1..n) AWS managed rule groups (start in count mode: override_action { count {} })
  dynamic "rule" {
    for_each = {
      AWSManagedRulesAmazonIpReputationList = 1
      AWSManagedRulesCommonRuleSet          = 2
      AWSManagedRulesKnownBadInputsRuleSet  = 3
      AWSManagedRulesSQLiRuleSet            = 4
      AWSManagedRulesPHPRuleSet             = 5
    }
    content {
      name     = rule.key
      priority = rule.value
      override_action {
        none {} # بعد فترة الـ count
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  # brute force on the login form
  rule {
    name     = "rate-limit-login"
    priority = 10
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit                 = 100
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                search_string         = "/login"
                positional_constraint = "EXACTLY"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "POST"
                positional_constraint = "EXACTLY"
                field_to_match {
                  method {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-login"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = module.alb.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.app.arn
}

resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${local.name}" # WAF requires the aws-waf-logs- prefix
  retention_in_days = 7
}

resource "aws_wafv2_web_acl_logging_configuration" "app" {
  resource_arn            = aws_wafv2_web_acl.app.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  redacted_fields {
    single_header {
      name = "x-lab-token"
    }
  }
}
```

ملاحظات: الـ rate-based rules بتقبل حد أدنى **10** requests و windows `60/120/300/600` ثانية، وبتتقيّم كل ~10 ثواني (مش rate limiting دقيق). لو فيه CloudFront قدّام الـ ALB، الـ IP الحقيقي في `X-Forwarded-For` → `aggregate_key_type = "FORWARDED_IP"`. والـ WAF على الـ ALB بيقف traffic الـ k6 بتاعك كمان — خلي بالك في الـ load tests (rate rules) ([74](74-load-testing-k6.md)).

### 5.5 `/metrics` و `/sre-lab/*` — طبقات الحماية

| Endpoint | التطبيق | الـ ALB (موجود) | مقترح |
|---|---|---|---|
| `/metrics` | 404 لو `METRICS_ENABLED` مش true؛ `METRICS_TOKEN` (Bearer) اختياري → 403 | rule priority 1 → fixed 404 | Prometheus يعمل scrape من جوه الـ VPC بس |
| `/sre-lab/*` | `EnsureSreLabEnabled`: 404 لو `SRE_LAB_ENABLED` مش true، 403 لو `SRE_LAB_TOKEN` متحدد ومش مبعوت في `X-Lab-Token` | **مش مقفول** — الـ stacks 20/40/50 بـ `sre_lab_enabled = true` افتراضياً، والـ token random في SSM (token-only) | **`sre_lab_enabled = false` على أي stack مش بتعمل عليه drills** ([CONVENTIONS §5](../CONVENTIONS.md))، أو WAF rule (§5.4) / ALB rule |

ALB rule بديل للـ WAF (**مش في الـ repo**) — ALB conditions مفيهاش "NOT"، فلو عايز allow من IP معين حط rule forward بـ `source_ip` قبلها:

```hcl
resource "aws_lb_listener_rule" "block_sre_lab" {
  listener_arn = module.alb.listener_arn
  priority     = 2
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
  condition {
    path_pattern {
      values = ["/sre-lab/*"]
    }
  }
}
```

الـ trade-off: الـ drills من GitHub Actions/k6 على الـ ALB (`autoscale-cpu.js`، `error-budget-burn.js`) هتقف — يا إما تقفل الـ rule وقت الـ game day، يا إما تعتمد على الـ token (32 حرف random) لوحده في الـ lab.

### 5.6 Shield

- **Standard**: مفعّل أوتوماتيك ومجاناً على كل ALB/CloudFront/Route 53 — SYN floods، UDP reflection، الـ L3/L4 الشائعة. مفيش حاجة تعملها.
- **Advanced**: L7 DDoS response team، cost protection، visibility — بـ اشتراك شهري كبير (~$3,000/شهر + data — تقريبي) — مش للـ lab.
- الـ L7 floods (HTTP) على الـ ALB = الـ WAF rate-based rules.

## 6) الـ Deploy

```bash
# 1) HTTPS (stack 40)
terraform apply -var domain_name=lab.<YOUR_DOMAIN> -var hosted_zone_id=<ZONE_ID> -var image_tag=<SHA7>
# 2) secure cookies: الـ apply فوق كتب SESSION_SECURE_COOKIE=true في SSM (stack 40) — الـ instances محتاجة refresh
aws ssm get-parameter --name /student-app/lab/app/SESSION_SECURE_COOKIE --query Parameter.Value --output text   # true
aws autoscaling start-instance-refresh --auto-scaling-group-name student-app-lab-blue
# 3) headers
aws elbv2 modify-listener-attributes --listener-arn "$(terraform output -raw listener_arn)" --attributes \
  '[{"Key":"routing.http.response.strict_transport_security.header_value","Value":"max-age=300"},{"Key":"routing.http.response.x_content_type_options.header_value","Value":"nosniff"}]'
# 4) WAF: من الـ Console (§4.4) أو أضف waf.tf (§5.4) و terraform apply
```

## 7) التحقق (Verify)

```bash
D=lab.<YOUR_DOMAIN>
curl -sI http://$D/ | grep -iE '^(HTTP|location)'                           # 301 → https://
curl -sI https://$D/login | grep -iE 'strict-transport|x-content-type|x-frame|server|set-cookie'
echo | openssl s_client -connect $D:443 -servername $D 2>/dev/null | grep -E 'Protocol|Cipher'
curl -s -o /dev/null -w 'metrics=%{http_code}\n' https://$D/metrics          # 404 من الـ ALB
curl -s -o /dev/null -w 'lab=%{http_code}\n' https://$D/sre-lab/ping         # 403 (token) / 404 (rule/WAF)
curl -s https://$D/login | grep -o 'action="[^"]*"' | head -2                # الفورم بـ https:// (trustProxies شغال)

# WAF
for i in $(seq 1 120); do curl -s -o /dev/null -w '%{http_code} ' -X POST https://$D/login; done; echo   # بعد شوية: 403 من الـ WAF
aws wafv2 get-sampled-requests --web-acl-arn <WEB_ACL_ARN> --rule-metric-name rate-limit-login --scope REGIONAL \
  --time-window StartTime=$(date -u -d '-30 min' +%s),EndTime=$(date -u +%s) --max-items 10
aws logs tail aws-waf-logs-student-app-lab --since 10m --format short | head
```

## 8) اكسرها (Break it): تمرين على الأعطال

| التمرين | الأمر/التعديل | المتوقع |
|---|---|---|
| شيل `trustProxies` (branch) | build + deploy خلف HTTPS | الفورمز والـ redirects بـ `http://` → الـ ALB يعمل redirect لـ https → loop/mixed content |
| Cert في region غلط | ACM في `eu-west-1` والـ ALB في `us-east-1` | مش هيظهر في الـ listener |
| HSTS بـ max-age كبير + رجعت HTTP | (فكّر) | المتصفحات اللي زارت هترفض http لحد ما المدة تخلص — ليه تبدأ بـ 300 |
| Common rule set Block من أول يوم | فورم student بـ notes طويلة | ممكن 403 (false positive) — ليه Count الأول وتقرا الـ logs |
| Rate limit على k6 | `load.js` بـ VUs كتير من IP واحد ضد ALB عليه WAF | 403 بعد الحد → `http_req_failed` ↑ — استثني IP الـ runner أو اقفل الـ rule وقت الـ test |
| `/sre-lab` من غير token | `curl https://$D/sre-lab/cpu?ms=5000` (لو مفيش WAF rule) | 403 — الـ token هو الحماية الوحيدة؛ لو `SRE_LAB_TOKEN` فاضي = أي حد يحرق CPU |
| WAF log group غلط | اسم من غير `aws-waf-logs-` | الـ logging configuration بيترفض |

## 9) الرجوع (Rollback)

```bash
aws wafv2 disassociate-web-acl --resource-arn <ALB_ARN>                    # أسرع "off switch" للـ WAF
aws elbv2 modify-listener-attributes --listener-arn <LISTENER_ARN> \
  --attributes Key=routing.http.response.strict_transport_security.header_value,Value=   # قيمة فاضية = default
# رجوع لـ HTTP بس (stack 40): شيل domain_name و hosted_zone_id من terraform.tfvars ثم
terraform apply -var image_tag=<SHA7>
```

## 10) المسح (Teardown) ⚠️

```bash
aws wafv2 disassociate-web-acl --resource-arn <ALB_ARN>
aws wafv2 delete-web-acl --name student-app-lab-waf --scope REGIONAL --id <WEB_ACL_ID> --lock-token <LOCK_TOKEN>   # من get-web-acl
aws logs delete-log-group --log-group-name aws-waf-logs-student-app-lab
aws ssm delete-parameter --name /student-app/lab/app/SESSION_SECURE_COOKIE     # بس لو عملته بإيدك (stack 50) — stack 40 بيمسحه مع destroy
```

الـ ACM cert والـ Route 53 records بيتمسحوا مع `terraform destroy` في stack 40؛ الـ hosted zone نفسها (لو عملتها بإيدك) $0.50/شهر لحد ما تمسحها.

## 11) التكلفة (Cost)

| Resource | السعر التقريبي (us-east-1 — تقريبي، راجع صفحة الأسعار) |
|---|---|
| AWS WAF web ACL (protection pack) | ~$5/شهر |
| كل rule أو managed rule group | ~$1/شهر (بعض الـ groups زي Bot Control / Fraud بتتحاسب زيادة) |
| WAF requests | ~$0.60 لكل مليون request |
| WAF logs | CloudWatch Logs ingestion |
| ACM public certificate | مجاني |
| Route 53 hosted zone | ~$0.50/شهر + queries (alias للـ ALB مجاني) |
| Shield Standard | مجاني · Advanced ~$3,000/شهر |

الـ snippet فوق (web ACL + 1 custom + 5 managed + 1 rate) ≈ $5 + 7 × $1 ≈ **$12/شهر** + الـ requests — اقفله (disassociate + delete) بعد التجربة أو اكتفي بـ 3 rules (~$8).

## 12) أسئلة Interview

<details><summary>ليه Laravel بيطلّع روابط `http://` ورا الـ ALB رغم إن المستخدم على https؟</summary>

الـ TLS بيتفك على الـ ALB، والـ request بيوصل PHP كـ HTTP. Laravel بيعرف الـ scheme الأصلي من `X-Forwarded-Proto` بس لو الـ proxy trusted (`trustProxies`). الـ repo بيعمل `trustProxies(at: '*', headers: HEADER_X_FORWARDED_PROTO)` — آمن لأن الـ SG بيسمح بالـ ALB بس — والـ client IP بيترجع من nginx جوه الـ container.

</details>

<details><summary>WAF managed rules: إزاي تفعّلهم من غير ما تكسر المستخدمين؟</summary>

Count mode الأول، logging مع redaction، تقرا الـ matches أسبوع (sampled requests + logs)، تعمل scope-down أو rule action override للـ rules اللي بتعمل false positives على paths معينة، وبعدين Block تدريجياً. ومراقبة 403 من الـ WAF كـ metric (لو قفزت بعد تغيير = false positives).

</details>

<details><summary>Rate limiting: في الـ WAF ولا في التطبيق؟</summary>

الاتنين. الـ WAF (rate-based، per IP، window دقايق) بيوقف الـ floods والـ brute force قبل ما يستهلكوا PHP workers — بس مش دقيق ومش عارف الـ user. التطبيق (Laravel throttle: هنا 5 محاولات login لكل email+IP) دقيق ومربوط بالـ business logic. والـ k6/الـ monitoring بتوعك لازم يبقوا مستثنيين أو تحت الحد.

</details>

<details><summary>إزاي تحمي `/metrics` والـ admin/debug endpoints؟</summary>

Defence in depth: مقفولة افتراضياً بـ env، token، block على الـ edge (الـ ALB rule بترجّع 404 لـ `/metrics` قبل ما يوصل التطبيق)، الـ scrape من جوه الـ VPC/الـ cluster، ومفيش public exposure للـ monitoring UIs (SSM port forwarding). `/sre-lab/*` في الـ lab محمي بالـ token بس — في environment حقيقي يتقفل على الـ edge أو يتشال خالص.

</details>

<details><summary>Shield Standard مقابل Advanced مقابل WAF؟</summary>

Shield Standard: مجاني وأوتوماتيك لـ L3/L4 على ALB/CloudFront/Route 53. WAF: L7 (HTTP) rules، rate limiting، managed rules — انت بتديره. Shield Advanced: للـ targets الحرجة — DDoS response team، cost protection من الـ scaling وقت الهجوم، L7 mitigations أوتوماتيك، وبيشمل WAF بدون تكلفة إضافية على الـ protected resources — غالي (اشتراك شهري كبير).

</details>

<details><summary>HSTS — إيه المخاطرة؟</summary>

بعد ما المتصفح يشوف `Strict-Transport-Security` هيرفض أي http للدومين (و الـ subdomains لو `includeSubDomains`) لحد ما الـ `max-age` يخلص، و `preload` بيدخل الدومين في قايمة المتصفحات نفسها (صعب جداً تطلع منها). لو subdomain لسه http هيقع. ابدأ بـ max-age صغير، اتأكد إن كل حاجة https، وبعدين كبّره.

</details>

## 13) Checklist

- [ ] عملت ACM cert بـ DNS validation و HTTPS listener + redirect 301 (Console أو `domain_name` في stack 40)
- [ ] اتأكدت إن الروابط في الـ HTML بـ https (trustProxies) وإن الـ cookie عليه `Secure` (`SESSION_SECURE_COOKIE=true` — أوتوماتيك في stack 40)
- [ ] ضفت security headers من الـ ALB وشفتهم في `curl -I`
- [ ] عملت WAF web ACL بـ managed rules (Count ثم Block) و rate-based على `/login` وشفته بيبلّك
- [ ] اتأكدت إن `/metrics` = 404 من برّه وقررت هتحمي `/sre-lab/*` إزاي
- [ ] مسحت الـ WAF والـ log group (التكلفة الشهرية)
