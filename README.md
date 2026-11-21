# Students Subscriptions

Multi-user system for managing students and their monthly subscriptions (Arabic, RTL, mobile-first).
Laravel 13 · Blade · Tailwind v4 · Alpine.js · PHPUnit. No API, no SPA, no cron/queue.

## Quick start

```bash
composer install && npm install
cp .env.example .env && php artisan key:generate
php artisan migrate --seed      # demo@example.com / password  (30 students, all statuses)
npm run build                   # or: npm run dev
php artisan test
```

## Architecture

```
app/
├── Casts/DateOnly.php                  # stores plain Y-m-d (identical comparisons on MySQL & SQLite)
├── Enums/
│   ├── SubscriptionStatus.php          # THE status rule: resolve() in PHP + constrain() in SQL, side by side
│   └── SubscriptionType.php            # initial | renewal
├── Models/
│   ├── Concerns/BelongsToUser.php      # tenant isolation: global scope + auto user_id
│   ├── Scopes/OwnedByAuthenticatedUserScope.php
│   ├── Student.php                     # status(), daysUntilRenewal(), whatsappUrl(), scopes, statusCounts()
│   ├── Subscription.php                # append-only ledger (update/delete throw)
│   └── User.php
├── Services/
│   ├── SubscriptionService.php         # ONLY writer of the ledger + denormalized dates (addStudent, renew)
│   ├── NotificationSyncService.php     # once-a-day digest on first screen visit (atomic claim)
│   └── RevenueReportService.php        # price/commission totals, per-day and entries for a from–to range
├── Support/
│   ├── SubscriptionPeriod.php          # calendar-month math: ends the day before the same day next month
│   └── WhatsApp/WhatsAppLinkBuilder.php# wa.me links + templates (swappable for a real API later)
├── Http/
│   ├── Controllers/{Student,Renewal,Notification,Report,Dashboard}Controller.php, Auth/*
│   ├── Requests/{Store,Update}StudentRequest, RenewStudentRequest, Auth/*
│   └── Middleware/
│       ├── PreventDuplicateSubmissions.php  # idempotency via one-off _submission_token
│       └── SyncRenewalNotifications.php
├── Notifications/RenewalDueNotification.php
├── Policies/StudentPolicy.php          # defense in depth on top of the global scope
└── View/Composers/NavigationComposer.php   # bell counter
config/subscriptions.php                # period_months, default price/commission, per_page, whatsapp country code, token TTL
lang/ar/*                               # every UI string & validation message
resources/views/
├── components/                         # x-form (loader+idempotency), x-button, x-input, x-modal,
│                                       # x-renewal-modal, x-status-badge, x-toast, x-icon, layouts/…
├── students/ · notifications/ · auth/ · dashboard.blade.php
```

## Key decisions

| Topic | Decision |
|---|---|
| Status | Computed, never stored. Due day = "renewal today" (🟠); expired starts the day after. Change it in `SubscriptionStatus` only. |
| Late renewal | Next period counts from the **renewal date** (spec §14 Q1 default). |
| Denormalized dates | `students.{first,last}_subscription_date`, `next_renewal_date` are not fillable; written only by `SubscriptionService` inside a transaction with row locks. |
| Numbering | `max(number)+1` per user under a lock on the user row; soft-deleted students keep their number. |
| Codes | Plain `unique(user_id, code)` — a deleted student's code stays reserved. |
| Double submit | UI loader (`submit` event) + `_submission_token` idempotency + DB unique constraints + PRG. |
| Isolation | Global scope → foreign records 404 via route binding; policy checks ownership again. |
| Notifications | Live lists/bell come from the DB on every request; the stored digest is an optional history layer. |

## Roadmap (spec phases 2–3)

CSV export, editable WhatsApp templates (`message_templates`), WhatsApp Cloud API.

## DevOps / SRE lab

This app doubles as a hands-on lab for every AWS deployment path, each done once in the Console and once as code:

- **Platforms:** EC2 + Docker Compose → ALB/ASG → ECS Fargate → EKS
- **CI/CD:** GitHub Actions + CodeBuild/CodePipeline/CodeDeploy
- **Zero-downtime strategies:** recreate, rolling, blue/green, canary, linear, A/B, shadow
- **SRE measured for real:** SLOs, burn-rate alerts, k6, chaos

| | |
|---|---|
| Start here (roadmap + 73 scenarios, Arabic) | [`docs/devops/README.md`](docs/devops/README.md) |
| Conventions (names, ports, SSM layout, SLOs) | [`docs/devops/CONVENTIONS.md`](docs/devops/CONVENTIONS.md) |
| One-file summary / full handbook | [`docs/devops/SUMMARY.pdf`](docs/devops/SUMMARY.pdf) · [`docs/devops/HANDBOOK.pdf`](docs/devops/HANDBOOK.pdf) |
| Container | [`docker/`](docker) · [`docker-compose.yml`](docker-compose.yml) |
| Infrastructure as code | [`infra/terraform`](infra/terraform) · [`infra/ansible`](infra/ansible) · [`infra/packer`](infra/packer) · [`k8s`](k8s) |
| Deploy scripts | [`deploy/`](deploy) (single-host blue/green, canary, rolling, A/B, shadow) |
| Observability & load tests | [`observability/`](observability) · [`loadtest/k6`](loadtest/k6) |
| Pipelines | [`.github/workflows`](.github/workflows) |

Health endpoints `/up` (liveness) and `/ready` (readiness, DB check) are always on. `/metrics` and `/sre-lab/*` are **off by default** (`METRICS_ENABLED`, `SRE_LAB_ENABLED`); see [`config/sre_lab.php`](config/sre_lab.php).
