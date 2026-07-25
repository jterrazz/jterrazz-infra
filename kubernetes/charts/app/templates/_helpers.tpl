{{/*
Application name
*/}}
{{- define "app.name" -}}
{{- .Values.metadata.name | required "metadata.name is required" -}}
{{- end -}}

{{/*
==============================================================================
app.merged — THE resolver (chart 2.3)
==============================================================================
The fully-resolved `spec` for the environment being rendered. Every template
starts with

  {{- $spec := fromYaml (include "app.merged" .) -}}

and then reads plain keys ($spec.port, $spec.env, $spec.resources.memory, …).

This replaces eight near-identical helpers that each re-implemented the same
"look up .Values.environments[.Values.environment], then pick a key out of it
or fall back to spec" preamble: app.envConfig (which was already dead code),
app.getValue, app.getResource, app.infisicalEnv, app.secretsConfig,
app.ingressList, app.envVars, and app.platformServices' merge half. Same
semantics, one implementation — and an environment can now override ANY spec
key, not just the six that happened to have a bespoke helper.

Semantics come from sprig's mergeOverwrite (spec first, environment second),
which is exactly the rule this chart already had:

  * scalars  — the environment's value wins, else spec's, else the caller's
               `| default`.
  * maps     — DEEP merged, environment wins per key. `resources: {memory: …}`
               in an environment keeps the base `cpu`; `env:` and `secrets:`
               merge key-by-key with THE ENVIRONMENT WINNING on a collision.
               (The 2.2 README claimed base wins on env/secrets collisions.
               That was never true — app.envVars called `merge $envEnv
               $baseEnv`, and sprig's `merge` does not overwrite keys already
               present in its first argument, so the environment's value
               survived. The doc was wrong, not the code; behaviour is
               unchanged here and the doc is fixed.)
  * lists    — REPLACED wholesale. An environment's `ingress` or
               `platformServices` list fully supersedes spec's, deliberately:
               a half-merged list of network surfaces is unreadable.

deepCopy because mergeOverwrite mutates its first argument, and .Values is
shared across every template in the render.
*/}}
{{- define "app.merged" -}}
{{- $env := .Values.environment | required "environment is required" -}}
{{- $envConfig := dict -}}
{{- if hasKey .Values.environments $env -}}
{{- $envConfig = index .Values.environments $env -}}
{{- end -}}
{{- mergeOverwrite (deepCopy (.Values.spec | default dict)) (deepCopy $envConfig) | toYaml -}}
{{- end -}}

{{/*
Check if current environment is defined.

Nothing renders for an environment that isn't declared under `environments:` —
a typo'd `--set environment=prd` produces an empty release rather than an
error. Turning that into a hard failure is a breaking change owned by a later
coordinated release; deliberately NOT done here.
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
Resolved ingress list plus the one check a values file can't express. The list
itself comes from app.merged (an environment's list replaces spec's).

  ingress:
    - host: signews.jterrazz.com          # public
      path: /api
      public: true
    - host: signews.internal.jterrazz.com # private — tailnet only
      path: /
      public: false

Returns YAML; consume via fromYamlArray.
*/}}
{{- define "app.ingressList" -}}
{{- $list := (fromYaml (include "app.merged" .)).ingress | default list -}}
{{- if not (kindIs "slice" $list) -}}
{{- fail "ingress must be a list of { host, path?, public? } entries. The single-object form was removed in chart 1.17.0 — migrate to a one-element list." -}}
{{- end -}}
{{- $list | toYaml -}}
{{- end -}}

{{/*
Full image name - can be overridden by Image Updater via spec.image
*/}}
{{- define "app.image" -}}
{{- $spec := fromYaml (include "app.merged" .) -}}
{{- if $spec.image -}}
{{- $spec.image -}}
{{- else -}}
registry.jterrazz.com/{{ include "app.name" . }}:latest
{{- end -}}
{{- end -}}

{{/*
Parse a memory quantity to an integer number of MiB. Returns "" for anything
that is not `<n>Mi` or `<n>Gi` — both callers treat that as "can't reason
about this, leave it alone".

  {{ include "app.memMi" "512Mi" }}  ->  512
  {{ include "app.memMi" "1Gi" }}    ->  1024

Shared by app.memoryLimit and app.nodeMaxOldSpace; each carried its own copy
of this suffix-sniffing before 2.3.
*/}}
{{- define "app.memMi" -}}
{{- $mem := . | toString -}}
{{- if hasSuffix "Mi" $mem -}}
{{- trimSuffix "Mi" $mem | int -}}
{{- else if hasSuffix "Gi" $mem -}}
{{- mul (trimSuffix "Gi" $mem | int) 1024 -}}
{{- end -}}
{{- end -}}

{{/*
Memory limit — explicit `resources.memoryLimit`, else 2x the request.

The derived limit is emitted in Mi as of 2.3: a `1Gi` request now yields
`2048Mi` where it used to yield `2Gi`. Identical quantity (1 Gi is exactly
1024 Mi); cosmetic manifest diff on the next deploy, no behaviour change.
A request in neither Mi nor Gi still passes through unchanged.
*/}}
{{- define "app.memoryLimit" -}}
{{- $resources := (fromYaml (include "app.merged" .)).resources | default dict -}}
{{- $memLimit := $resources.memoryLimit | default "" -}}
{{- if $memLimit -}}
{{- $memLimit -}}
{{- else -}}
{{- $mem := $resources.memory | default "256Mi" -}}
{{- $mi := include "app.memMi" $mem -}}
{{- if $mi -}}
{{- printf "%dMi" (mul ($mi | int) 2) -}}
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
{{- $resources := (fromYaml (include "app.merged" .)).resources | default dict -}}
{{- $mem := $resources.memory | default "256Mi" -}}
{{- $reqMi := include "app.memMi" $mem | default "0" | int -}}
{{- if ge $reqMi 512 -}}
{{- div (mul $reqMi 3) 4 -}}
{{- end -}}
{{- end -}}

{{/*
Infisical environment — the `secretsEnv` override if the environment sets one,
otherwise the deploy environment's own name.
*/}}
{{- define "app.infisicalEnv" -}}
{{- (fromYaml (include "app.merged" .)).secretsEnv | default .Values.environment -}}
{{- end -}}

{{/*
Slug a hostname for use in resource names: dots → dashes, lowercase.
signews.jterrazz.com → signews-jterrazz-com
*/}}
{{- define "app.hostSlug" -}}
{{- . | lower | replace "." "-" -}}
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
Validated opt-in platform services for the current environment. The list is
resolved by app.merged (an environment's list REPLACES spec's, same rule as
`ingress`); this helper adds the name check.

Fails fast on an unknown service name (typo protection) — validation lives
here, in the single accessor every consumer (env injection, client labels,
netpol) already calls, so a bad name can never render a silently-broken
manifest. Returns a YAML list (consume via fromYamlArray).
*/}}
{{- define "app.platformServices" -}}
{{- $catalog := fromYaml (include "app.platformCatalog" .) -}}
{{- $services := (fromYaml (include "app.merged" .)).platformServices | default list -}}
{{- range $svc := $services -}}
{{- if not (hasKey $catalog $svc) -}}
{{- fail (printf "spec.platformServices: unknown service %q (valid: %s)" $svc (keys $catalog | sortAlpha | join ", ")) -}}
{{- end -}}
{{- end -}}
{{- $services | toYaml -}}
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
Common labels.

`app.kubernetes.io/instance` is .Release.Name as of 2.3, where it used to be
the reconstructed "<environment>-<name>". CI installs as
`helm upgrade --install <env>-<app>`, so for every real deploy the two are the
same string — but the release name is the authoritative identity, and
reconstructing it meant the label quietly lied for any install under a
different release name (e.g. a local `helm template`/`helm install` while
debugging).
*/}}
{{- define "app.labels" -}}
app: {{ include "app.name" . }}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
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
