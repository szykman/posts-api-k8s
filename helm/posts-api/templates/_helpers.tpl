{{/* Chart name, overridable. */}}
{{- define "posts-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified name: the release name, unless it already contains the chart name. */}}
{{- define "posts-api.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Labels shared by every object. */}}
{{- define "posts-api.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "posts-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Immutable selector labels. Each template adds its own app.kubernetes.io/component. */}}
{{- define "posts-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "posts-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "posts-api.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}

{{/* Database host: explicit value, or the in-cluster MariaDB Service. */}}
{{- define "posts-api.dbHost" -}}
{{- if .Values.database.host -}}
{{- .Values.database.host -}}
{{- else -}}
{{- printf "%s-db" (include "posts-api.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* TypeORM connection settings. Credentials always come from the Secret. */}}
{{- define "posts-api.dbEnv" -}}
- name: TYPEORM_HOST
  value: {{ include "posts-api.dbHost" . | quote }}
- name: TYPEORM_PORT
  value: {{ .Values.database.port | quote }}
- name: TYPEORM_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: MYSQL_USER
- name: TYPEORM_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: MYSQL_PASSWORD
- name: TYPEORM_DATABASE
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: MYSQL_DATABASE
{{- end -}}

{{/*
Hash of the token Secret, as a pod annotation. The Secret is created out-of-band, so changing it does not by
itself change the Deployment; with this annotation the next `helm upgrade` rolls the pods and they pick up
the new token. `lookup` returns nothing on `helm template` and `--dry-run`, hence the fixed fallback.
*/}}
{{- define "posts-api.authChecksum" -}}
{{- $secret := lookup "v1" "Secret" .Release.Namespace .Values.auth.existingSecret -}}
checksum/auth-secret: {{ if $secret }}{{ $secret.data | toJson | sha256sum }}{{ else }}unknown{{ end }}
{{- end -}}

{{- define "posts-api.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 1000
runAsGroup: 1000
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "posts-api.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop:
    - ALL
{{- end -}}

{{/* Init container: waits (bounded) until the database accepts TCP connections. */}}
{{- define "posts-api.waitForDb" -}}
- name: wait-for-db
  image: {{ include "posts-api.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command:
    - node
    - -e
    - |
      const net = require("net");
      const deadline = Date.now() + {{ mul .Values.migration.waitTimeoutSeconds 1000 }};
      (function attempt() {
        const socket = net.connect(Number(process.env.TYPEORM_PORT), process.env.TYPEORM_HOST);
        socket.on("connect", () => { socket.end(); process.exit(0); });
        socket.on("error", () => {
          if (Date.now() > deadline) { console.error("database not reachable"); process.exit(1); }
          setTimeout(attempt, 2000);
        });
      })();
  env:
    {{- include "posts-api.dbEnv" . | nindent 4 }}
  securityContext:
    {{- include "posts-api.containerSecurityContext" . | nindent 4 }}
  resources:
    requests:
      cpu: 10m
      memory: 64Mi
    limits:
      memory: 128Mi
{{- end -}}
