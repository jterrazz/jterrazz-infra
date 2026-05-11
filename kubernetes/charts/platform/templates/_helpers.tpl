{{- define "platform.name" -}}
{{- required "name is required" .Values.name -}}
{{- end -}}

{{- define "platform.host" -}}
{{- required "host is required" .Values.host -}}
{{- end -}}
