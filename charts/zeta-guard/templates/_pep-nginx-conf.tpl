{{- /* vim: set ft=helm: */ -}}
{{- define "zeta-guard.pep-nginx-conf" -}}

worker_processes auto;

{{- with .Values.pepproxy.nginxConf }}

load_module modules/libngx_pep.so;
{{- if $.Values.pepproxyTracingEnabled }}
load_module modules/ngx_otel_module.so;
{{- end }}

error_log  /dev/stdout debug;
pid        /var/run/nginx.pid;

events {
  worker_connections 16384;
  multi_accept       on;
  use                epoll;
}

http {
  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
  }
  proxy_read_timeout 300s;

  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;

  log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
  '$status $body_bytes_sent ${request_time}s "$http_referer" '
  '"$http_user_agent" "$http_x_forwarded_for"';

  access_log  /dev/stdout  main;

  sendfile    on;
  aio         threads;
  aio_write   on;
  tcp_nopush  on;

  keepalive_timeout  65;

  gzip  on;

  {{- if $.Values.pepproxyTracingEnabled }}
  otel_exporter {
    endpoint {{ include "telemetryGateway.hostname" $ }}:4317;
  }
  otel_trace          on;
  otel_trace_context  inject;
  {{- end }}

  pep_pdp_issuer {{ .pepIssuer }};
  pep_http_client_accept_invalid_certs {{ .httpClientAcceptInvalidCerts | ternary "on" "off" }};

  # override global default, can still be toggled on per-location
  pep_require_popp    off;
  pep_popp_issuer     {{  required "pepproxy.nginxConf.poppIssuer is require" $.Values.pepproxy.nginxConf.poppIssuer }};
  pep_asl_testing {{ .aslTestmode | ternary "on" "off" }};

  server {
    listen 8081;
    server_name  pep-proxy-svc;
    {{- tpl $.Values.pepproxy.nginxConf.locations $ | nindent 4 }}
    client_body_temp_path /dev/shm;
    proxy_temp_path /dev/shm;
    fastcgi_temp_path /dev/shm;
    uwsgi_temp_path /dev/shm;
    scgi_temp_path /dev/shm;
  }
  server {
    listen 8080;
    location = /status {
      access_log off;
      stub_status;
    }
    client_body_temp_path /dev/shm;
    proxy_temp_path /dev/shm;
    fastcgi_temp_path /dev/shm;
    uwsgi_temp_path /dev/shm;
    scgi_temp_path /dev/shm;
  }
}
{{- end }}
{{- end -}}
