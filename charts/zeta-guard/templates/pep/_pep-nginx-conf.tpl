{{- /* vim: set ft=helm: */ -}}
{{- define "zeta-guard.pep-nginx-conf" -}}

worker_processes auto;

{{- with .Values.pepproxy.nginxConf }}

load_module modules/libngx_pep.so;
{{- if $.Values.pepproxyTracingEnabled }}
load_module modules/ngx_otel_module.so;
{{- end }}

error_log /dev/stdout debug;
{{- if $.Values.telemetryGatewayEnabled }}
error_log syslog:server={{ include "telemetryGateway.hostname" $ }}:54526 debug;
{{- end }}
pid /tmp/nginx.pid;

events {
    worker_connections 16384;
    multi_accept on;
    use epoll;
}

http {
    include common.conf;

    access_log /dev/stdout main;
    {{- if $.Values.telemetryGatewayEnabled }}
    access_log syslog:server={{ include "telemetryGateway.hostname" $ }}:54526 main;
    {{- end }}

    client_body_temp_path /tmp/client_body_temp;
    proxy_temp_path /tmp/proxy_temp;
    scgi_temp_path /tmp/scgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;

    ### Global Config

    pep_pdp_issuer {{ .pepIssuer }};
    ## server hosting PoPP entity statement at /.well-known/openid-federation
    ## optional if no locations use pep_require_popp
    {{- if .poppIssuer }}
    pep_popp_issuer {{ .poppIssuer }};
    pep_popp_validity "{{ .poppValidity }}";
    {{- end }}
    # pep_http_client_connect_timeout 2; # s
    # pep_http_client_timeout 10; # s
    pep_http_client_accept_invalid_certs {{ .httpClientAcceptInvalidCerts | ternary "on" "off" }};
    ## enable or disable no-travel enforcement (ip address consistency)
    pep_no_travel {{ .noTravel | ternary "on" "off" }};
    {{- if $.Values.pepproxy.asl_enabled }}
    pep_asl_testing {{ .aslTestmode | ternary "on" "off" }};
    pep_asl_signer_cert /etc/nginx/signer_cert.pem;
    pep_asl_signer_key /etc/nginx/signer_key.pem;
    pep_asl_ca_cert /etc/nginx/issuer_cert.pem;
    pep_asl_roots_json /var/trust-data/roots.json;
    {{- with $.Values.pepproxy.aslRootCA }}
    pep_asl_root_ca {{ . | quote }};
    {{- end }}
    {{- with $.Values.pepproxy.aslOcsp }}
    ## cert: use AuthorityInformationAccess (AIA) from cert (default)
    ## off: disable OCSP checks
    ## https://ocsp.example.org: override responder, ignore cert AIA
    pep_asl_ocsp {{ . | quote }};
    {{- end }}
    {{- with $.Values.pepproxy.aslOcspTtl }}
    pep_asl_ocsp_ttl {{ . | quote }};
    {{- end }}
    {{- end }}
    {{- if $.Values.pepproxyTracingEnabled }}
    otel_resource_attr "service.version" "{{ $.Values.pepproxy.image.tag }}";
    otel_service_name "ZETA Guard PEP HTTP proxy";
    {{- end }}

    ### Location Config

    ## These can be set per-location, but it is recommended to set them once globally, and
    ## only override in specific locations as needed.
    ## enable access phase handler to check access tokens, DPoP and, optionally, PoPP
    pep on;
    ## space separated list of required audiences
    pep_require_aud {{ .requiredAudience }};
    ## space separated list of required scopes
    {{- with .requiredScopes }}
    pep_require_scope {{ join " " . | quote }};
    {{- end }}
    ## clock leeway when checking exp,nbf,iat claims in s, default: 60
    # pep_leeway 60;
    ## implied dpop validity in s: iat + pep_dpop_validity + pep_leeway
    # pep_dpop_validity 300;
    ## validate PoPP header and pass decoded claims as ZETA-PoPP-Token-Content to upstream
    {{- if .poppIssuer }}
    pep_require_popp on;
    {{- end }}
    ## implied ppop validity in s
    # pep_ppop_validity 31536000;
    ## forward client data to upstream
    # pep_forward_client_data off;

    server {
        listen 8081;
        {{- if $.Values.pepproxy.hsmProxyAddr }}
        listen 8443 ssl;
        ssl_certificate "tls.p256.pem";
        ## NOTE: set HSM_PROXY_ADDR="https://hsm:50051" environment variable to use
        ## store:hsm with the ossl_hsm provider
        ssl_certificate_key "store:hsm:tls.p256";
        {{- end }}

        server_name pep-proxy-svc;

        include server_common.conf;

        root /usr/share/nginx/html;

        {{- if $.Values.pepproxy.asl_enabled }}
        allow 127.0.0.1;
        deny all;

        include asl.conf;
        {{- end }}

        # Proxy OAuth Authorization Server metadata to Keycloak
        # Served as: http(s)://<host>/.well-known/oauth-authorization-server
        # Target:   http://authserver/auth/realms/zeta-guard/.well-known/zeta-guard-well-known
        location /.well-known/ {
            pep off;

            satisfy all;
            allow all;

            default_type application/json;
            alias /srv/.well-known/;
            autoindex off;
            location = /.well-known/oauth-authorization-server {
                proxy_pass http://authserver/auth/realms/zeta-guard/.well-known/zeta-guard-well-known;
                proxy_http_version 1.1;
            }
        }

        {{- if $.Values.authserver.adminHostname }}
        # Block public access to Keycloak Admin REST API and Admin Console.
        # /auth is routed through the PEP proxy so this location takes effect.
        location ~ ^/auth/admin {
            return 403;
        }
        # Route all other /auth/* requests to Keycloak (no token required).
        location /auth {
            pep off;
            proxy_pass http://authserver;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            # Pass through the proto set by the TLS-terminating ingress ($scheme would
            # be "http" here since the ingress talks to the PEP proxy over plain HTTP).
            proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
        }
        {{- end }}
        {{- tpl .locations $ | nindent 8 }}
    }

    {{- if $.Values.pepproxyTracingEnabled }}
    otel_exporter {
        endpoint {{ include "telemetryGateway.hostname" $ }}:4317;
    }
    otel_trace on;
    otel_trace_context inject;
    {{- end }}

    server {
        listen 8080;

        location = /status {
            pep off;
            access_log off;
            stub_status;
        }
    }
}

{{- end }}
{{- end -}}
