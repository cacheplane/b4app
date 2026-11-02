{{/* Chart name. */}}
{{- define "b4hub.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Full name: <release>-b4hub unless the release name already contains the chart name. */}}
{{- define "b4hub.fullname" -}}
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

{{- define "b4hub.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Labels common to every resource. */}}
{{- define "b4hub.labels" -}}
helm.sh/chart: {{ include "b4hub.chart" . }}
app.kubernetes.io/name: {{ include "b4hub.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels for a component: pass (dict "ctx" $ "component" "hub"). */}}
{{- define "b4hub.selectorLabels" -}}
app.kubernetes.io/name: {{ include "b4hub.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "b4hub.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "b4hub.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. global.imageRegistry replaces the registry portion of image.repository (the first
path segment when it looks like a host: has a dot or a colon, or is localhost), or is prefixed when
the repository has none. image.digest wins over image.tag.
*/}}
{{- define "b4hub.image" -}}
{{- $repo := .Values.image.repository }}
{{- with .Values.global.imageRegistry }}
{{- $parts := splitList "/" $repo }}
{{- $first := first $parts }}
{{- if and (gt (len $parts) 1) (or (contains "." $first) (contains ":" $first) (eq "localhost" $first)) }}
{{- $repo = printf "%s/%s" (trimSuffix "/" .) (join "/" (rest $parts)) }}
{{- else }}
{{- $repo = printf "%s/%s" (trimSuffix "/" .) $repo }}
{{- end }}
{{- end }}
{{- if .Values.image.digest }}
{{- printf "%s@%s" $repo .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" $repo (default .Chart.AppVersion .Values.image.tag | toString) }}
{{- end }}
{{- end }}

{{/* True ("true") when the chart creates the evaluation database Secret. */}}
{{- define "b4hub.db.createSecret" -}}
{{- if and (not .Values.database.existingSecret) .Values.database.urls.url .Values.database.urls.adminUrl }}true{{ end }}
{{- end }}

{{/* Name of the database Secret; fails when neither existingSecret nor both urls are set. */}}
{{- define "b4hub.db.secretName" -}}
{{- if .Values.database.existingSecret }}
{{- .Values.database.existingSecret }}
{{- else if include "b4hub.db.createSecret" . }}
{{- printf "%s-db" (include "b4hub.fullname" .) }}
{{- else }}
{{- required "database.existingSecret is required (or set both database.urls.url and database.urls.adminUrl, for evaluation only)" "" }}
{{- end }}
{{- end }}

{{/* True ("true") when any hub sign-in secret value is set, so the chart creates the hub Secret. */}}
{{- define "b4hub.secrets.createSecret" -}}
{{- if not .Values.secrets.existingSecret }}
{{- with .Values.secrets.values }}
{{- if or .secretKey .appleTeamId .appleKeyId .applePrivateKey }}true{{ end }}
{{- end }}
{{- end }}
{{- end }}

{{/* Name of the hub secrets Secret, or empty when sign-in secrets are not configured. */}}
{{- define "b4hub.secrets.secretName" -}}
{{- if .Values.secrets.existingSecret }}
{{- .Values.secrets.existingSecret }}
{{- else if include "b4hub.secrets.createSecret" . }}
{{- printf "%s-secrets" (include "b4hub.fullname" .) }}
{{- end }}
{{- end }}

{{/* The hub secret keys, in a fixed order. */}}
{{- define "b4hub.secrets.keys" -}}
B4HUB_SECRET_KEY B4HUB_APPLE_TEAM_ID B4HUB_APPLE_KEY_ID B4HUB_APPLE_PRIVATE_KEY
{{- end }}

{{/* Name of the migration Job for this revision. */}}
{{- define "b4hub.migrateJobName" -}}
{{- printf "%s-migrate-%d" (include "b4hub.fullname" . | trunc 50 | trimSuffix "-") (int .Release.Revision) }}
{{- end }}

{{/* Pod-level settings shared by the hub and the migration Job. */}}
{{- define "b4hub.podCommon" -}}
automountServiceAccountToken: false
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
securityContext:
  {{- toYaml .Values.podSecurityContext | nindent 2 }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
