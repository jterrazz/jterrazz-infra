{{- define "platform.name" -}}
{{- required "name is required" .Values.name -}}
{{- end -}}

{{- define "platform.host" -}}
{{- required "host is required" .Values.host -}}
{{- end -}}

{{- define "platform.dnsTarget" -}}
{{- if .Values.private -}}
{{- .Values.infrastructure.tailscaleHostname -}}
{{- else -}}
{{- .Values.infrastructure.publicIp -}}
{{- end -}}
{{- end -}}
