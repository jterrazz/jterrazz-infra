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
==============================================================================
Platform-service catalog (chart 2.0)
==============================================================================
Single source of truth for the in-cluster platform services an app can opt
into via `spec.platformServices: [ ... ]`. Declaring a service wires the whole
bundle from this catalog: env injection (client side) + egress NetworkPolicy +
(for a service that IS a catalog target, e.g. gateway-intelligence) the
server-side ingress rule via a pod label selector.

Per entry:
  env         map of env var name -> value injected into opted-in consumers.
              A user-set env of the same name always wins (see deployment.yaml).
  egress      { namespace, ports[] } — the consumer's egress NetworkPolicy hole.
              ports are the POD ports (NOT the Service port). Namespace is
              pinned (gateway-intelligence only exists in prod).
  clientLabel (optional) pod label the consumer stamps on its own pods; the
              target service's chart-rendered ingress rule selects on it, so a
              new consumer needs ZERO edit on the target.

Auth model (Option A): the gateway has NO client-API-key enforcement — the
security boundary is netpol + private ingress. So gateway-intelligence has NO
secret here; consumers pass a non-secret static placeholder apiKey to satisfy
the OpenAI SDK (which requires a non-empty string). See CLAUDE.md.

Note OTEL_EXPORTER_OTLP_ENDPOINT keeps its spec-mandated name (the OTel SDK
owns that contract — the one naming exception); GATEWAY_INTELLIGENCE_BASE_URL
is service-name-derived and carries the /v1 suffix the OpenAI client expects.
*/}}
{{- define "app.platformCatalog" -}}
otel-collector:
  env:
    OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.platform-telemetry:4318"
  egress:
    namespace: platform-telemetry
    ports:
      - 4317
      - 4318
gateway-intelligence:
  env:
    GATEWAY_INTELLIGENCE_BASE_URL: "http://gateway-intelligence.prod-gateway-intelligence.svc.cluster.local/v1"
  egress:
    namespace: prod-gateway-intelligence
    ports:
      - 8317
  clientLabel: platform-client.jterrazz.com/gateway-intelligence
{{- end -}}

{{/*
Opt-in platform services for the current environment.
env-level `platformServices` fully replaces the spec-level list (same
replace-not-merge semantics as `ingress`); otherwise the spec list applies.
Returns a YAML list (consume via fromYamlArray).
*/}}
{{- define "app.platformServices" -}}
{{- $env := .Values.environment -}}
{{- $base := .Values.spec.platformServices | default list -}}
{{- $envConfig := dict -}}
{{- if hasKey .Values.environments $env -}}
{{- $envConfig = index .Values.environments $env -}}
{{- end -}}
{{- if hasKey $envConfig "platformServices" -}}
{{- (index $envConfig "platformServices") | toYaml -}}
{{- else -}}
{{- $base | toYaml -}}
{{- end -}}
{{- end -}}

{{/*
Fail fast on an unknown platformServices entry (typo protection). Included at
the top of every template that consumes the catalog so a bad name never renders
a silently-broken netpol.
*/}}
{{- define "app.validatePlatformServices" -}}
{{- $catalog := fromYaml (include "app.platformCatalog" .) -}}
{{- range $svc := (fromYamlArray (include "app.platformServices" .)) -}}
{{- if not (hasKey $catalog $svc) -}}
{{- fail (printf "spec.platformServices: unknown service %q (valid: %s)" $svc (keys $catalog | sortAlpha | join ", ")) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Merged env-var map (name -> value) injected by all opted-in platform services.
*/}}
{{- define "app.platformEnv" -}}
{{- $catalog := fromYaml (include "app.platformCatalog" .) -}}
{{- $out := dict -}}
{{- range $svc := (fromYamlArray (include "app.platformServices" .)) -}}
{{- if hasKey $catalog $svc -}}
{{- $entry := index $catalog $svc -}}
{{- if $entry.env -}}
{{- range $k, $v := $entry.env -}}
{{- $_ := set $out $k $v -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}

{{/*
Client labels (label -> "true") this consumer stamps on its own pods, so the
target platform service's ingress selects it. Empty for services w/o a label.
*/}}
{{- define "app.platformClientLabels" -}}
{{- $catalog := fromYaml (include "app.platformCatalog" .) -}}
{{- $out := dict -}}
{{- range $svc := (fromYamlArray (include "app.platformServices" .)) -}}
{{- if hasKey $catalog $svc -}}
{{- $entry := index $catalog $svc -}}
{{- if $entry.clientLabel -}}
{{- $_ := set $out $entry.clientLabel "true" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $out | toYaml -}}
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
