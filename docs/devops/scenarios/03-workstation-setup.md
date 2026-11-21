# 03 — تجهيز الجهاز (Windows 11 + WSL2 + الأدوات)

> **الهدف في سطر:** جهاز Windows 11 فيه WSL2 Ubuntu وكل أدوات المعمل (Terraform، AWS CLI v2 بـ SSO، kubectl، helm، eksctl، kind، k6، gh، Ansible...) — ومسار بديل كامل **من غير Docker محلي** عن طريق GitHub Actions.
> **المستوى:** Beginner · **الوقت:** ~2 ساعة · **التكلفة التقريبية:** مجاني
> **بيعتمد على:** [01 — الأدوات](01-tools-primer.md) · [02 — تجهيز حساب AWS](02-aws-account-setup.md) (عشان `aws configure sso`) · **الملفات في الـ repo:** [`.github/workflows/lab-integration.yml`](../../../.github/workflows/lab-integration.yml) · [`.gitattributes`](../../../.gitattributes)

## 1) الفكرة (Concepts)

كل سكريبتات المعمل bash ومكتوبة لـ Linux (EC2 بيشغّل Amazon Linux، والـ runners بتاعة GitHub Ubuntu). عشان كده بيئة الشغل الأساسية هي **WSL2 Ubuntu**، مش PowerShell. الـ Windows بيفضل للـ browser و VS Code و Laragon.

عندك 3 اختيارات للـ Docker، اختار حسب موارد جهازك:

| الاختيار | المميزات | العيوب | لمين |
|---|---|---|---|
| **A. من غير Docker محلي** (GitHub Actions) | صفر RAM على جهازك، نفس الـ runner اللي بيعمل CI | كل تجربة = push + انتظار دقائق، مفيش shell تفاعلي | **الأول لما الموارد قليلة** |
| **B. Docker Engine جوه WSL2** | خفيف، مجاني، Linux أصلي، نفس اللي على EC2 | محتاج تشغّله جوه WSL، مفيش GUI | لما يبقى عندك ≥ 16GB RAM |
| **C. Docker Desktop** | GUI، تكامل مع Windows | تقيل، الترخيص مدفوع للشركات الكبيرة | لو متعوّد عليه |

> 💡 القاعدة: **متفتحش B و C مع بعض** — الاتنين بيتخانقوا على الـ socket. اختار واحد.

| المصطلح | المعنى |
|---|---|
| WSL2 | Linux kernel حقيقي جوه VM خفيفة على Windows |
| `.wslconfig` | ملف في `%UserProfile%` بيحدد RAM/CPU لـ WSL كله |
| AWS SSO profile | profile في `~/.aws/config` بياخد credentials مؤقتة من IAM Identity Center |
| `/mnt/c` | الـ C: drive من جوه WSL — **بطيء** في الـ I/O، اشتغل في `~` |

## 2) المعمارية (Architecture)

```text
 Windows 11
 ├─ VS Code (+ WSL extension) ─────────────┐
 ├─ Browser (AWS Console, GitHub)          │ remote
 ├─ Laragon (PHP محلي للتطوير العادي)        ▼
 └─ WSL2: Ubuntu 24.04  ~/src/StudentHub  (الشغل كله هنا)
      ├─ git, gh, jq, aws (SSO), session-manager-plugin
      ├─ terraform, packer, ansible (pipx)
      ├─ kubectl, helm, eksctl, kind, k6
      └─ docker engine (اختيار B)  ──or──  push → GitHub Actions (اختيار A)
                                              └─ lab-integration.yml: compose + k6 + lb scripts
```

## 3) المتطلبات (Prerequisites)

- [ ] Windows 11 + صلاحية Administrator.
- [ ] Virtualization متفعّل في الـ BIOS (Task Manager → Performance → CPU → `Virtualization: Enabled`).
- [ ] حساب GitHub عليه الـ repo `Ahmed-Reda-Ragab/StudentHub`.
- [ ] حساب AWS متجهّز بـ IAM Identity Center ([02](02-aws-account-setup.md)) — هتحتاج الـ **start URL** (`https://<SUBDOMAIN>.awsapps.com/start`).

## 4) الطريقة الأولى: AWS Console (يدوي) — اللي محتاجه للـ CLI

مفيش موارد هنا، بس محتاج 3 معلومات من الـ Console عشان `aws configure sso`:

1. **IAM Identity Center → Settings → Identity source** → انسخ الـ **AWS access portal URL** (ده الـ start URL).
2. **IAM Identity Center → Settings** → لاحظ الـ **Region** اللي الـ Identity Center متفعّل فيها (غالباً `us-east-1`).
3. **IAM Identity Center → AWS accounts** → اتأكد إن الـ user بتاعك متعيّن على الحساب بـ permission set (مثلاً `AdministratorAccess` للمعمل، وفي [80](80-iam-oidc-least-privilege.md) بنقلّلها).

> 💡 ليه SSO مش access keys؟ الـ credentials بتنتهي لوحدها (ساعات)، مفيش secret محفوظ على الـ disk طول العمر، وكل حاجة متسجّلة باسمك في CloudTrail.

## 5) الطريقة التانية: as code — تثبيت الأدوات بأوامر

### 5.1 WSL2 + Ubuntu (من PowerShell كـ Administrator)

```powershell
wsl --install -d Ubuntu-24.04
wsl --set-default-version 2
wsl -l -v
```

حدّد الموارد (مهم لو الجهاز ضعيف) — اعمل الملف `C:\Users\<YOU>\.wslconfig`:

```ini
[wsl2]
memory=4GB
processors=2
swap=2GB
```

```powershell
wsl --shutdown
```

جوه Ubuntu اتأكد إن systemd شغال (الإصدارات الجديدة بتفعّله افتراضياً):

```bash
cat /etc/wsl.conf                 # المفروض فيه [boot] systemd=true
ps -p 1 -o comm=                  # المفروض: systemd
```

لو مش موجود:

```bash
printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf
```
وبعدين `wsl --shutdown` من PowerShell.

### 5.2 الأساسيات

```bash
sudo apt-get update && sudo apt-get install -y git curl unzip jq make ca-certificates gnupg lsb-release pipx dnsutils
pipx ensurepath
git config --global user.name "<YOUR_NAME>"
git config --global user.email "<YOUR_EMAIL>"
git config --global core.autocrlf input
```

> ⚠️ الـ repo فيه `.gitattributes` بـ `* text=auto eol=lf`، فالسكريبتات هتطلع LF. بس **الـ executable bit**: على Windows الـ `core.filemode=false`، فلو عملت commit لسكريبتات جديدة من Windows ممكن تتسجل `100644`. ابني عادة إنك تشغّل السكريبتات بـ `bash script.sh`، أو صلّح الـ mode من WSL: `git update-index --chmod=+x <file>.sh`.

### 5.3 Docker (اختيار B: Engine جوه WSL)

```bash
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sudo sh /tmp/get-docker.sh
sudo usermod -aG docker "$USER"
newgrp docker
docker version && docker compose version && docker buildx version
```

> اختيار C: نزّل Docker Desktop وفعّل **Settings → Resources → WSL integration** للـ distro بتاعك. متثبتش Engine جوه WSL في الحالة دي.

### 5.4 AWS CLI v2 + Session Manager plugin

```bash
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install --update
aws --version

curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o session-manager-plugin.deb
sudo dpkg -i session-manager-plugin.deb
session-manager-plugin --version
```

إعداد الـ SSO:

```bash
aws configure sso
# SSO session name:        lab
# SSO start URL:           https://<SUBDOMAIN>.awsapps.com/start
# SSO region:              us-east-1
# SSO registration scopes: sso:account:access   (Enter)
# → هيفتح browser (أو يديك code) → اختار الحساب والـ role
# Default client Region:   us-east-1
# CLI default output:      json
# Profile name:            lab
```

```bash
aws sso login --profile lab
aws sts get-caller-identity --profile lab
echo 'export AWS_PROFILE=lab' >> ~/.bashrc && source ~/.bashrc
```

### 5.5 Terraform + Packer (HashiCorp apt repo)

```bash
wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform packer
terraform version    # لازم >= 1.10 (S3 native locking)
```

### 5.6 Ansible (pipx — معزول عن Python بتاع النظام)

```bash
pipx install --include-deps ansible
pipx inject ansible boto3 botocore
pipx install ansible-lint
ansible --version
ansible-galaxy collection install amazon.aws community.docker
```

### 5.7 Kubernetes tools

```bash
# kubectl (آخر stable)
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl

# helm 4
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 -o /tmp/get_helm.sh
less /tmp/get_helm.sh            # اقرا السكريبت قبل ما تشغّله
bash /tmp/get_helm.sh

# eksctl
curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
sudo install -m 0755 /tmp/eksctl /usr/local/bin/eksctl

# kind
curl -fsSLo /tmp/kind https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-amd64
sudo install -m 0755 /tmp/kind /usr/local/bin/kind
```

> 💡 kubectl لازم يكون في حدود ±1 minor version من الـ EKS cluster. لو الـ cluster أقدم، نزّل نسخة محددة بدل `stable.txt`.

### 5.8 k6 و gh و Trivy (اختياري محلياً)

```bash
# k6
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install -y k6

# GitHub CLI
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
sudo apt-get update && sudo apt-get install -y gh
gh auth login          # GitHub.com → HTTPS → login with a web browser
```

> بدائل على Windows نفسه لو حبيت: `winget install --id GitHub.cli` و `winget install k6 --source winget`.

### 5.9 ShellCheck و hadolint (عشان تشغّل نفس الـ lint محلياً)

```bash
sudo apt-get install -y shellcheck
docker pull hadolint/hadolint      # لو عندك Docker؛ غير كده سيبه للـ CI
```

## 6) الـ Deploy — أول تشغيل للمعمل

### 6.1 الـ clone جوه WSL (مش `/mnt/c`)

```bash
mkdir -p ~/src && cd ~/src
gh repo clone Ahmed-Reda-Ragab/StudentHub
cd StudentHub
git switch devops-lab
```

> لو عايز تفتح نفس الـ repo من Laragon على Windows: اشتغل في نسخة WSL و افتحها بـ VS Code (`code .` من جوه WSL). متشتغلش على نسختين وتنسى أيهم فيها التعديلات.

### 6.2 مسار B/C: Docker محلي

```bash
export APP_KEY=base64:$(openssl rand -base64 32)
docker compose up -d --build --wait
docker compose run --rm app php artisan migrate --force
curl -s http://localhost:8080/ready
```

التفاصيل كاملة في [10 — تحويل التطبيق لـ container](10-containerize-app.md).

### 6.3 مسار A: **من غير Docker محلي** — GitHub Actions هو المعمل بتاعك

[`lab-integration.yml`](../../../.github/workflows/lab-integration.yml) بيشغّل على runner Ubuntu نفس اللي كنت هتعمله محلياً: يبني `ci-v1` و `ci-v2`، يشغّل compose + MySQL، migrations + seeders، smoke tests، login حقيقي، k6 smoke + load، SRE drills، وبعدين كل سكريبتات الـ zero-downtime (blue/green → rollback → rolling → canary → bad canary → A/B → shadow) مع probe بيأكد **0 failed requests**.

بيشتغل لوحده على `push` لـ `master`/`main`/`devops-lab` **لو** اتغيّر ملف في `app/`، `config/`، `routes/`، `database/`، `resources/`، `docker/`، `docker-compose*.yml`، `deploy/`، `loadtest/`، `composer.lock`، `package-lock.json` أو الـ workflow نفسه، وعلى أي `pull_request`، ويدوياً بـ `workflow_dispatch`.

```bash
# 1) اعمل تعديل (مثلاً في deploy/ec2/lb/bin/canary.sh) واعمل push
git add -A && git commit -m "lab: try canary with STEP_SECONDS=20"
git push origin devops-lab

# 2) أو شغّله يدوياً من غير commit
gh workflow run lab-integration.yml --ref devops-lab

# 3) تابع
gh run list --workflow=lab-integration.yml --limit 3
gh run watch                         # اختار الـ run
gh run view <RUN_ID> --log-failed    # لو فشل: آخر سطور الـ steps الفاشلة بس
gh run view <RUN_ID> --log > /tmp/lab.log && grep -n "probe summary" -A10 /tmp/lab.log
```

إزاي تقرا النتيجة:

| Job | لو أخضر يبقى اتأكدنا من | فين تبص لو أحمر |
|---|---|---|
| `Build ci-v1 + ci-v2` | الـ Dockerfile بيبني (والـ cache شغال) | step الـ build → غالباً composer/npm |
| `Compose · smoke · k6 · SRE drills` | التطبيق بيقوم مع MySQL، الـ login شغال، الـ SLO thresholds معدّية | step `Logs on failure` بيطبع `docker compose logs` |
| `Zero-downtime scripts (single host)` | كل استراتيجية عملت 0 failed requests | الـ `probe summary` في الـ step + `Final status` (= `status.sh`) |

> 💡 على الـ **push**: الـ `docs/**` و `*.md` مستثناة من `ci.yml` (`paths-ignore`)، و `lab-integration.yml` بيشتغل بس على الـ paths اللي فوق. على الـ **pull_request** مفيش paths filter — كل PR بيشغّل الـ workflows (عشان الـ required checks تتبعت دايماً).

## 7) التحقق (Verify)

```bash
for c in git gh jq aws session-manager-plugin terraform packer ansible ansible-lint kubectl helm eksctl kind k6 shellcheck; do
  printf '%-24s' "$c"; command -v "$c" >/dev/null && echo OK || echo MISSING
done
terraform version | head -1
aws --version
kubectl version --client
helm version --short
eksctl version
kind version
k6 version
aws sts get-caller-identity --profile lab
gh auth status
docker run --rm hello-world        # لو اخترت B/C
```

المفروض تشوف كل الأدوات `OK`، و `get-caller-identity` بيرجع الـ account والـ role بتاع الـ SSO (`AWSReservedSSO_...`).

## 8) اكسرها (Break it): المشاكل المشهورة

| العَرَض | السبب | الحل |
|---|---|---|
| `The SSO session associated with this profile has expired` | الـ token انتهى (طبيعي) | `aws sso login --profile lab` |
| `Signature expired` / TLS errors بعد sleep للجهاز | ساعة WSL اتأخرت | `sudo hwclock -s` أو `wsl --shutdown` |
| `Temporary failure in name resolution` جوه WSL | VPN أو DNS | جرّب `networkingMode=mirrored` تحت `[wsl2]` في `.wslconfig`، أو اقفل الـ VPN |
| `permission denied ... docker.sock` | الـ user مش في group docker | `sudo usermod -aG docker $USER` ثم افتح shell جديد |
| `bash: ./x.sh: Permission denied` | الـ exec bit ضاع (commit من Windows) | `bash x.sh` أو `git update-index --chmod=+x x.sh` |
| `$'\r': command not found` | CRLF (الملف اتعدّل/اتنسخ من Windows) | `sed -i 's/\r$//' <file>.sh` و `git config --global core.autocrlf input` |
| الـ build بطيء جداً | الـ repo على `/mnt/c` | انقله لـ `~/src` |
| WSL واكل الـ RAM | مفيش limit | `.wslconfig` (فوق) + `wsl --shutdown` |

## 9) الرجوع (Rollback)

خد snapshot للـ distro بعد ما تخلّص التثبيت، وارجع لها لو بوّظت حاجة:

```powershell
wsl --shutdown
wsl --export Ubuntu-24.04 D:\backup\ubuntu-lab.tar
# للرجوع:
wsl --unregister Ubuntu-24.04
wsl --import Ubuntu-24.04 D:\WSL\Ubuntu-24.04 D:\backup\ubuntu-lab.tar
```

## 10) المسح (Teardown) ⚠️

مفيش موارد AWS. لتحرير موارد الجهاز بعد كل جلسة:

```bash
docker compose down                 # من جوه الـ repo (من غير -v عشان الداتابيز تفضل)
kind delete cluster --name student-app 2>/dev/null || true
docker system prune -f
```
```powershell
wsl --shutdown
```

## 11) التكلفة (Cost)

| Resource | السعر التقريبي |
|---|---|
| كل الأدوات | مجاني |
| GitHub Actions | مجاني للـ public repo؛ الـ private عنده دقائق شهرية مجانية (راجع صفحة GitHub billing) |
| Docker Desktop | مجاني للاستخدام الشخصي؛ مدفوع للشركات الكبيرة |

## 12) أسئلة Interview

<details><summary>ليه بتشتغل على WSL2 مش Git Bash أو PowerShell؟</summary>

عشان الـ parity: الـ production (EC2/AL2023، containers، runners) Linux. سكريبتات bash، الـ file permissions، الـ line endings، و Docker networking بتتصرف زي الـ production. Git Bash بيقلّد بس، وفيه فروقات (paths، `date`، signals) بتطلع bugs مش هتشوفها غير في الـ CI.

</details>

<details><summary>إزاي بتدير AWS credentials على جهازك؟</summary>

IAM Identity Center + `aws configure sso`: credentials مؤقتة بتتجدد بـ `aws sso login`، مفيش access keys في `~/.aws/credentials`. لكل حساب/role profile، و `AWS_PROFILE` بيحدد أنهي واحد. للـ automation (CI) بستخدم OIDC roles، مش credentials بشرية.

</details>

<details><summary>إيه البديل لو مفيش Docker على جهازك ومحتاج تختبر deploy scripts؟</summary>

أشغّلها على CI runner بـ workflow مخصوص (زي `lab-integration.yml`) بيحاكي الـ host: env files مكان SSM، نفس الـ compose files والسكريبتات، مع assertions (probe بـ `MAX_FAILURES=0`). الـ feedback loop أبطأ، بس النتيجة reproducible ومتسجلة. البدائل التانية: Codespaces/dev container، أو EC2 صغير بـ Session Manager.

</details>

<details><summary>ليه kubectl لازم يكون قريب من نسخة الـ cluster؟</summary>

الـ version skew policy بتاعة Kubernetes بتضمن توافق kubectl مع الـ API server في حدود minor version واحدة لفوق أو لتحت. أبعد من كده ممكن flags أو API versions تختفي أو تتصرف مختلف، وأخطاء صعب تفهمها.

</details>

<details><summary>إزاي تضمن إن الأدوات على جهازك نفس اللي في الـ CI؟</summary>

أثبّت النسخ (Terraform `required_version` + lock file، Docker images بـ tags/digests، actions بـ SHA)، وأشغّل نفس الأوامر (نفس `shellcheck -x -S warning`، نفس `hadolint`). الأحسن كمان dev container أو Makefile بيستخدم نفس الـ images اللي الـ CI بيستخدمها.

</details>

## 13) Checklist

- [ ] WSL2 Ubuntu شغال بـ systemd و `.wslconfig` محدد الموارد
- [ ] كل الأدوات بتطلع `OK` في أمر الـ verify
- [ ] `aws sts get-caller-identity --profile lab` شغال بالـ SSO
- [ ] اخترت مسار Docker (A أو B أو C) وجرّبته
- [ ] شغّلت `lab-integration.yml` على `devops-lab` وقريت الـ probe summary
- [ ] عملت `wsl --export` snapshot
