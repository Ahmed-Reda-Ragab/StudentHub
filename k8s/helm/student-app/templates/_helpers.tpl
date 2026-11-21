{{/*
Names
*/}}
{{- define "student-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "student-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "student-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "student-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image. Tags are immutable git SHAs (CONVENTIONS §2): "latest" is refused at render time so it can
never reach a cluster through this chart.
*/}}
{{- define "student-app.imageTag" -}}
{{- $tag := toString (default .Chart.AppVersion .Values.image.tag) }}
{{- if eq $tag "latest" }}
{{- fail "image.tag=latest is not allowed — deploy an immutable git SHA (CONVENTIONS §2)" }}
{{- end }}
{{- $tag }}
{{- end }}

{{- define "student-app.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "student-app.imageTag" .) }}
{{- end }}

{{/*
Labels. Selector labels never change after the first install (selectors are immutable), so the
version lives in the regular labels only. CONVENTIONS §8.
*/}}
{{- define "student-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "student-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: web
{{- end }}

{{- define "student-app.commonLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "student-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ include "student-app.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: student-app-lab
{{- end }}

{{- define "student-app.labels" -}}
{{ include "student-app.commonLabels" . }}
app.kubernetes.io/component: web
{{- end }}

{{/*
Environment-scoped config (ConfigMap). Null values are skipped so an environment file can drop a
default with `KEY: null`.
*/}}
{{- define "student-app.configData" -}}
{{- range $key, $value := .Values.config }}
{{- if not (kindIs "invalid" $value) }}
{{ $key }}: {{ $value | toString | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Release-scoped env, rendered into the pod template (NOT the ConfigMap): DEPLOY_COLOR, the SRE_FAULT_*
"bad release" knobs and extraEnv. Why: every ReplicaSet keeps its own copy. If these lived in the
shared ConfigMap, a bad canary's SRE_FAULT_ERROR_RATE would leak into *stable* pods that restart or
scale back up while the canary is being aborted. Changing them also changes the pod template, which
is exactly what makes Argo Rollouts start a new canary.
One dict → no duplicate env names (duplicates break server-side apply); extraEnv wins.
*/}}
{{- define "student-app.releaseEnv" -}}
{{- $env := dict
      "DEPLOY_COLOR" .Values.deployColor
      "SRE_FAULT_ERROR_RATE" .Values.faults.errorRate
      "SRE_FAULT_LATENCY_MS" .Values.faults.latencyMs
      "SRE_FAULT_UNHEALTHY" .Values.faults.unhealthy
      "SRE_FAULT_BOOT_FAIL" .Values.faults.bootFail }}
{{- $env = merge (deepCopy (default dict .Values.extraEnv)) $env }}
{{- range $key, $value := $env }}
{{- if not (kindIs "invalid" $value) }}
- name: {{ $key }}
  value: {{ $value | toString | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
`env` of the migration Job: extraEnv without the SRE_FAULT_* knobs (they simulate a bad *app pod*,
not a bad one-off task) and no `php artisan optimize` at start. The config itself comes from the
hook ConfigMap in migrate-job.yaml, so the precedence is the same as in the app pods:
config < Secret < extraEnv.
*/}}
{{- define "student-app.jobEnv" -}}
{{- $extra := dict }}
{{- range $key, $value := (default dict .Values.extraEnv) }}
{{- if not (hasPrefix "SRE_FAULT_" $key) }}
{{- $_ := set $extra $key $value }}
{{- end }}
{{- end }}
{{- $env := merge (dict "AUTORUN_ENABLED" "false") $extra }}
{{- range $key, $value := $env }}
{{- if not (kindIs "invalid" $value) }}
- name: {{ $key }}
  value: {{ $value | toString | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Pod template shared by the Deployment and the Rollout, so switching rollout.enabled never changes
what runs — only who rolls it out. Called with (dict "root" $ "hashLabel" "<label>"): the hash label
is pod-template-hash for Deployments and rollouts-pod-template-hash for Rollouts.
*/}}
{{- define "student-app.podTemplate" -}}
{{- $root := .root -}}
metadata:
  labels:
    {{- include "student-app.selectorLabels" $root | nindent 4 }}
    app.kubernetes.io/version: {{ include "student-app.imageTag" $root | quote }}
    app.kubernetes.io/part-of: student-app-lab
    {{- with $root.Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  annotations:
    # Roll the pods when the ConfigMap changes (pods read env only at start).
    checksum/config: {{ include (print $root.Template.BasePath "/configmap.yaml") $root | sha256sum }}
    {{- if $root.Values.metrics.podAnnotations }}
    # Annotation-based discovery (prometheus-community/prometheus "kubernetes-pods" job, used on kind).
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: /metrics
    {{- end }}
    {{- with $root.Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  serviceAccountName: {{ include "student-app.serviceAccountName" $root }}
  # The app never calls the Kubernetes API: no token in the pod.
  automountServiceAccountToken: false
  enableServiceLinks: false
  # preStop sleep + PHP-FPM graceful stop (SIGQUIT, ≤ 30 s) must fit in this budget.
  terminationGracePeriodSeconds: {{ $root.Values.terminationGracePeriodSeconds }}
  {{- with $root.Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- toYaml $root.Values.podSecurityContext | nindent 4 }}
  {{- if $root.Values.topologySpread.enabled }}
  # Best-effort spread over zones and nodes; matchLabelKeys = skew computed per revision.
  topologySpreadConstraints:
    {{- range list "topology.kubernetes.io/zone" "kubernetes.io/hostname" }}
    - maxSkew: 1
      topologyKey: {{ . }}
      whenUnsatisfiable: {{ $root.Values.topologySpread.whenUnsatisfiable }}
      labelSelector:
        matchLabels:
          {{- include "student-app.selectorLabels" $root | nindent 10 }}
      matchLabelKeys:
        - {{ $.hashLabel }}
    {{- end }}
  {{- end }}
  {{- with $root.Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $root.Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $root.Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: app
      image: {{ include "student-app.image" $root }}
      imagePullPolicy: {{ $root.Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: 8080
          protocol: TCP
      # ConfigMap first, Secret second: a key in both (e.g. DB_HOST from SSM) comes from the Secret.
      envFrom:
        - configMapRef:
            name: {{ include "student-app.fullname" $root }}
        - secretRef:
            name: {{ $root.Values.existingSecret }}
      # `env` beats `envFrom`: release-scoped values and extraEnv override everything above.
      env:
        {{- include "student-app.releaseEnv" $root | trim | nindent 8 }}
      {{- with $root.Values.probes }}
      # startup gives a slow first boot up to periodSeconds × failureThreshold before liveness kicks in.
      startupProbe:
        httpGet:
          path: {{ .startup.path }}
          port: http
        periodSeconds: {{ .startup.periodSeconds }}
        timeoutSeconds: {{ .startup.timeoutSeconds }}
        failureThreshold: {{ .startup.failureThreshold }}
      # liveness on /up (no DB): a DB outage must not become a restart storm.
      livenessProbe:
        httpGet:
          path: {{ .liveness.path }}
          port: http
        periodSeconds: {{ .liveness.periodSeconds }}
        timeoutSeconds: {{ .liveness.timeoutSeconds }}
        failureThreshold: {{ .liveness.failureThreshold }}
      # readiness on /ready (DB ping, drain flag): failing = out of the Service endpoints, not restarted.
      readinessProbe:
        httpGet:
          path: {{ .readiness.path }}
          port: http
        periodSeconds: {{ .readiness.periodSeconds }}
        timeoutSeconds: {{ .readiness.timeoutSeconds }}
        failureThreshold: {{ .readiness.failureThreshold }}
        successThreshold: 1
      {{- end }}
      lifecycle:
        # Keep serving while endpoint/target removal propagates (kube-proxy, ALB), then the runtime
        # sends the image STOPSIGNAL (SIGQUIT → graceful PHP-FPM). Native action: no shell needed.
        preStop:
          sleep:
            seconds: {{ $root.Values.preStopSleepSeconds }}
      resources:
        {{- toYaml $root.Values.resources | nindent 8 }}
      securityContext:
        {{- toYaml $root.Values.containerSecurityContext | nindent 8 }}
{{- end }}
