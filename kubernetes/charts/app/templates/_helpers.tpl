{{/*
Application name
*/}}
{{- define "app.name" -}}
{{- .Values.metadata.name | required "metadata.name is required" -}}
{{- end -}}

{{/*
Get current environment config (returns empty dict if not defined)
*/}}
{{- define "app.envConfig" -}}
{{- $env := .Values.environment | required "environment is required" -}}
{{- if hasKey .Values.environments $env -}}
{{- index .Values.environments $env | toYaml -}}
{{- else -}}
{{- dict | toYaml -}}
{{- end -}}
{{- end -}}

{{/*
Check if current environment is defined
*/}}
{{- define "app.envExists" -}}
{{- $env := .Values.environment -}}
{{- if and $env (hasKey .Values.environments $env) -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Get merged value: environment override > base spec > default
Usage: include "app.getValue" (dict "ctx" . "key" "replicas" "default" 1)
*/}}
{{- define "app.getValue" -}}
{{- $env := .ctx.Values.environment -}}
{{- $envConfig := dict -}}
{{- if hasKey .ctx.Values.environments $env -}}
{{- $envConfig = index .ctx.Values.environments $env -}}
{{- end -}}
{{- if hasKey $envConfig .key -}}
{{- index $envConfig .key -}}
{{- else if hasKey .ctx.Values.spec .key -}}
{{- index .ctx.Values.spec .key -}}
{{- else -}}
{{- .default -}}
{{- end -}}
{{- end -}}

{{/*
Get nested merged value for resources
*/}}
{{- define "app.getResource" -}}
{{- $env := .ctx.Values.environment -}}
{{- $envConfig := dict -}}
{{- if hasKey .ctx.Values.environments $env -}}
{{- $envConfig = index .ctx.Values.environments $env -}}
{{- end -}}
{{- $envResources := dict -}}
{{- if hasKey $envConfig "resources" -}}
{{- $envResources = index $envConfig "resources" -}}
{{- end -}}
{{- if hasKey $envResources .key -}}
{{- index $envResources .key -}}
{{- else if hasKey .ctx.Values.spec.resources .key -}}
{{- index .ctx.Values.spec.resources .key -}}
{{- else -}}
{{- .default -}}
{{- end -}}
{{- end -}}

{{/*
Namespace - {environment}-{name} format
*/}}
{{- define "app.namespace" -}}
{{ .Values.environment }}-{{ include "app.name" . }}
{{- end -}}

{{/*
Full image name - can be overridden by Image Updater via spec.image
*/}}
{{- define "app.image" -}}
{{- if .Values.spec.image -}}
{{- .Values.spec.image -}}
{{- else -}}
registry.jterrazz.com/{{ include "app.name" . }}:latest
{{- end -}}
{{- end -}}

{{/*
Memory limit (defaults to 2x memory request)
*/}}
{{- define "app.memoryLimit" -}}
{{- $memLimit := include "app.getResource" (dict "ctx" . "key" "memoryLimit" "default" "") -}}
{{- if $memLimit -}}
{{- $memLimit -}}
{{- else -}}
{{- $mem := include "app.getResource" (dict "ctx" . "key" "memory" "default" "256Mi") -}}
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
Node.js V8 old-space cap (MiB) ≈ 75% of the memory *request*, but ONLY
for apps requesting >= 512Mi. Rationale: without --max-old-space-size
V8 sizes its heap off the (2x) cgroup limit and drifts toward it — but
that drift only matters for large apps (e.g. signews-api at 768Mi).
Small Next.js services (~128Mi) already run lean (~80Mi RSS); deriving
a cap from their tiny request (96MB) starves SSR boot and crash-loops
them (regressed spwn.sh once — see git history). So below 512Mi we
return "" and the caller skips injection, preserving the safe
uncapped default. Also returns "" for non-Mi/Gi requests.
*/}}
{{- define "app.nodeMaxOldSpace" -}}
{{- $mem := include "app.getResource" (dict "ctx" . "key" "memory" "default" "256Mi") -}}
{{- $reqMi := 0 -}}
{{- if hasSuffix "Mi" $mem -}}
{{- $reqMi = trimSuffix "Mi" $mem | int -}}
{{- else if hasSuffix "Gi" $mem -}}
{{- $reqMi = mul (trimSuffix "Gi" $mem | int) 1024 -}}
{{- end -}}
{{- if ge $reqMi 512 -}}
{{- div (mul $reqMi 3) 4 -}}
{{- end -}}
{{- end -}}

{{/*
Infisical environment - uses secretsEnv override if set, otherwise maps to environment
*/}}
{{- define "app.infisicalEnv" -}}
{{- $env := .Values.environment -}}
{{- $envConfig := dict -}}
{{- if hasKey .Values.environments $env -}}
{{- $envConfig = index .Values.environments $env -}}
{{- end -}}
{{- if hasKey $envConfig "secretsEnv" -}}
{{- $envConfig.secretsEnv -}}
{{- else -}}
{{- $env -}}
{{- end -}}
{{- end -}}

{{/*
Get secrets config - merge base spec.secrets with environment secrets override
*/}}
{{- define "app.secretsConfig" -}}
{{- $env := .Values.environment -}}
{{- $baseSecrets := .Values.spec.secrets | default dict -}}
{{- $envConfig := dict -}}
{{- if hasKey .Values.environments $env -}}
{{- $envConfig = index .Values.environments $env -}}
{{- end -}}
{{- $envSecrets := $envConfig.secrets | default dict -}}
{{- merge $envSecrets $baseSecrets | toYaml -}}
{{- end -}}

{{/*
Get ingress list for the current environment.

Apps declare `ingress` as a LIST of surface entries, each with
{ host, path?, public? }. The env's list fully replaces a spec-level
list (no per-entry merge — keep manifests explicit). Returns YAML so
the template can consume via fromYamlArray.

  ingress:
    - host: signews.jterrazz.com         # public
      path: /api
      public: true
    - host: signews.internal.jterrazz.com# private — tailnet only
      path: /
      public: false
*/}}
{{- define "app.ingressList" -}}
{{- $env := .Values.environment -}}
{{- $envConfig := dict -}}
{{- if hasKey .Values.environments $env -}}
{{- $envConfig = index .Values.environments $env -}}
{{- end -}}
{{- $list := list -}}
{{- if hasKey $envConfig "ingress" -}}
{{- $list = $envConfig.ingress -}}
{{- else if .Values.spec.ingress -}}
{{- $list = .Values.spec.ingress -}}
{{- end -}}
{{- if not (kindIs "slice" $list) -}}
{{- fail "ingress must be a list of { host, path?, public? } entries. The single-object form was removed in chart 1.17.0 — migrate to a one-element list." -}}
{{- end -}}
{{- $list | toYaml -}}
{{- end -}}

{{/*
Slug a hostname for use in resource names: dots → dashes, lowercase.
signews.jterrazz.com → signews-jterrazz-com
*/}}
{{- define "app.hostSlug" -}}
{{- . | lower | replace "." "-" -}}
{{- end -}}

{{/*
Get env vars - merge base spec.env with environment env
*/}}
{{- define "app.envVars" -}}
{{- $env := .Values.environment -}}
{{- $baseEnv := .Values.spec.env | default dict -}}
{{- $envConfig := dict -}}
{{- if hasKey .Values.environments $env -}}
{{- $envConfig = index .Values.environments $env -}}
{{- end -}}
{{- $envEnv := $envConfig.env | default dict -}}
{{- merge $envEnv $baseEnv | toYaml -}}
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
app.kubernetes.io/instance: {{ .Values.environment }}-{{ include "app.name" . }}
app.kubernetes.io/managed-by: helm
environment: {{ .Values.environment }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "app.selectorLabels" -}}
app: {{ include "app.name" . }}
environment: {{ .Values.environment }}
{{- end -}}
