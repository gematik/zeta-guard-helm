{{- /* vim: set ft=helm: */ -}}
{{- /* Structured proxy-location API (pepproxy.nginxConf.proxyLocations).

     Each entry renders into
       - an http-level `upstream` block with connection keepalive (avoids
         per-request upstream connections -> TIME_WAIT ephemeral-port
         exhaustion under load), and
       - an exact-match + trailing-slash location PAIR (a bare prefix
         location would also match e.g. /pep/foo/wsDERP),
     with `include proxy_headers.conf` (the PEP's credential strips +
     enforcement sentinel) always present.

     The raw `locations` string remains the escape hatch for anything this
     API does not cover. */ -}}

{{- define "zeta-guard.pep-upstream-name" -}}
pep-{{ .path | trimPrefix "/" | replace "/" "__" }}-upstream
{{- end }}

{{- /* Validation shared by both render passes; fails the render with an
     entry-specific message instead of producing broken nginx config. */ -}}
{{- define "zeta-guard.pep-proxy-validate" -}}
{{- $path := .path | required "proxyLocations entry: `path` is required" }}
{{- if not (hasPrefix "/" $path) }}{{ fail (printf "proxyLocations %s: path must start with /" $path) }}{{- end }}
{{- if hasSuffix "/" $path }}{{ fail (printf "proxyLocations %s: path must not end with / (the exact+prefix location pair is generated)" $path) }}{{- end }}
{{- $up := .upstream | required (printf "proxyLocations %s: `upstream` is required" $path) }}
{{- if not (or (hasPrefix "http://" $up) (hasPrefix "https://" $up)) }}{{ fail (printf "proxyLocations %s: upstream must be http(s)://host[:port] (got %q)" $path $up) }}{{- end }}
{{- if contains "/" (regexReplaceAll "^https?://" $up "") }}{{ fail (printf "proxyLocations %s: upstream must not contain a path — use `upstreamPath` (got %q)" $path $up) }}{{- end }}
{{- with .upstreamPath }}{{- if not (hasPrefix "/" .) }}{{ fail (printf "proxyLocations %s: upstreamPath must start with /" $path) }}{{- end }}{{- end }}
{{- end }}

{{- /* http-level upstream blocks. Call with (dict "root" $ "locations" <list>). */ -}}
{{- define "zeta-guard.pep-proxy-upstreams" -}}
{{- range .locations }}
{{- include "zeta-guard.pep-proxy-validate" . }}
{{- $hostport := regexReplaceAll "^https?://" .upstream "" }}
{{- /* inside an upstream block `server host;` defaults to :80 REGARDLESS of
     the proxy_pass scheme (unlike a plain proxy_pass, which defaults per
     scheme) — supply the scheme's default port explicitly */}}
{{- if not (contains ":" $hostport) }}
{{- $hostport = printf "%s:%s" $hostport (hasPrefix "https://" .upstream | ternary "443" "80") }}
{{- end }}
upstream {{ include "zeta-guard.pep-upstream-name" . }} {
    server {{ $hostport }} max_fails=1 fail_timeout=10s;
    ## reuse connections instead of opening one per request (TIME_WAIT budget)
    keepalive {{ .keepalive | default 32 }};
}
{{ end }}
{{- end }}

{{- /* Shared per-location body. Call with (dict "root" $ "loc" <entry> "scheme" <s> "hostport" <h>). */ -}}
{{- define "zeta-guard.pep-proxy-location-body" -}}
{{- $loc := .loc }}
## credential strips + enforcement sentinel
include proxy_headers.conf;
## with an `upstream {}` block, nginx's default Host ($proxy_host) is the
## upstream block NAME — Tomcat rejects the underscores with HTTP 400.
## Send the real backend host instead.
proxy_set_header Host {{ .hostport | quote }};
## required for upstream keepalive (and for WebSocket upgrades)
proxy_http_version 1.1;
{{- if $loc.websocket }}
## hop-by-hop upgrade plumbing; $connection_upgrade maps '' -> '' (see
## http_common.conf), so plain requests stay keepalive-compatible
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_set_header Sec-WebSocket-Protocol $http_sec_websocket_protocol;
{{- else }}
proxy_set_header Connection "";
{{- end }}
{{- if eq .scheme "https" }}
## SNI for pooled TLS upstream connections
proxy_ssl_server_name on;
proxy_ssl_name {{ regexReplaceAll ":\\d+$" .hostport "" }};
{{- end }}
{{- if $loc.bypassAsl }}
## SECURITY: publicly reachable WITHOUT the ASL protocol — overrides the
## server-level `allow 127.0.0.1; deny all;` applied when asl_enabled.
## Only use when your resource server's spec permits direct access here.
satisfy all;
allow all;
{{- end }}
{{- with $loc.extraConfig }}
{{ tpl . $.root }}
{{- end }}
{{- end }}

{{- /* Server-level location pairs. Call with (dict "root" $ "locations" <list>). */ -}}
{{- define "zeta-guard.pep-proxy-locations" -}}
{{- $root := .root }}
{{- range .locations }}
{{- include "zeta-guard.pep-proxy-validate" . }}
{{- $name := include "zeta-guard.pep-upstream-name" . }}
{{- $scheme := hasPrefix "https://" .upstream | ternary "https" "http" }}
{{- $hostport := regexReplaceAll "^https?://" .upstream "" }}
{{- $upPath := .upstreamPath | default "/" }}
{{- $body := include "zeta-guard.pep-proxy-location-body" (dict "root" $root "loc" . "scheme" $scheme "hostport" $hostport) }}
location = {{ .path }} {
    proxy_pass {{ $scheme }}://{{ $name }}{{ $upPath }};
    {{- $body | nindent 4 }}
}
location {{ .path }}/ {
    proxy_pass {{ $scheme }}://{{ $name }}{{ eq $upPath "/" | ternary "/" (printf "%s/" $upPath) }};
    {{- $body | nindent 4 }}
}
{{ end }}
{{- end }}

{{- /* WebSocket paths the NIC must handle (ws minion): derived from
     proxyLocations entries with websocket: true. Empty (e.g. raw `locations`
     users) keeps the legacy blanket websocket-services annotation on the
     main minion. Returns a JSON array — consume with fromJsonArray. */ -}}
{{- define "zeta-guard.ingress-ws-paths" -}}
{{- $paths := list }}
{{- range ((.Values.pepproxy).nginxConf).proxyLocations }}
{{- if .websocket }}{{- $paths = append $paths .path }}{{- end }}
{{- end }}
{{- $paths | uniq | toJson -}}
{{- end }}
