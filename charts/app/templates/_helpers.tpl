{{/*
Application name
*/}}
{{- define "app.name" -}}
{{- .Values.metadata.name | required "metadata.name is required" -}}
{{- end -}}

{{/*
Namespace - simple app-{name} format
*/}}
{{- define "app.namespace" -}}
app-{{ include "app.name" . }}
{{- end -}}

{{/*
Image tag - always latest
*/}}
{{- define "app.imageTag" -}}
latest
{{- end -}}

{{/*
Full image name
*/}}
{{- define "app.image" -}}
registry.jterrazz.com/{{ include "app.name" . }}:{{ include "app.imageTag" . }}
{{- end -}}

{{/*
Memory limit (defaults to 2x memory request)
*/}}
{{- define "app.memoryLimit" -}}
{{- if .Values.spec.resources.memoryLimit -}}
{{- .Values.spec.resources.memoryLimit -}}
{{- else -}}
{{- $mem := .Values.spec.resources.memory -}}
{{- if hasSuffix "Mi" $mem -}}
{{- $val := trimSuffix "Mi" $mem | int -}}
{{- printf "%dMi" (mul $val 2) -}}
{{- else if hasSuffix "Gi" $mem -}}
{{- $val := trimSuffix "Gi" $mem | int -}}
{{- printf "%dGi" (mul $val 2) -}}
{{- else -}}
{{- $mem -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Infisical environment - always prod
*/}}
{{- define "app.infisicalEnv" -}}
prod
{{- end -}}

{{/*
Secrets name
*/}}
{{- define "app.secretsName" -}}
{{ include "app.name" . }}-secrets
{{- end -}}

{{/*
Common labels
*/}}
{{- define "app.labels" -}}
app: {{ include "app.name" . }}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ include "app.name" . }}
app.kubernetes.io/managed-by: helm
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "app.selectorLabels" -}}
app: {{ include "app.name" . }}
{{- end -}}
