{{- define "service.name" -}}
{{- required "name is required" .Values.name -}}
{{- end -}}

{{- define "service.host" -}}
{{- required "host is required" .Values.host -}}
{{- end -}}

{{/*
Common labels, stamped on every object this chart emits (IngressRoute,
Certificate, PV, PVC).

`part-of: jterrazz-infrastructure` is deliberate continuity: the deleted
kustomize base (kubernetes/infrastructure/base/kustomization.yaml) stamped
that exact pair — part-of jterrazz-infrastructure + managed-by — on every
cluster object it applied, and nothing ever selected on it. Keeping the
part-of label here preserves the "this belongs to the platform, not to an
app" grouping for `kubectl get -l` spelunking; managed-by is `helm` because
this chart is installed by Helm, not by kustomize.
*/}}
{{- define "service.labels" -}}
app.kubernetes.io/name: {{ include "service.name" . }}
app.kubernetes.io/part-of: jterrazz-infrastructure
app.kubernetes.io/managed-by: helm
{{- end -}}
