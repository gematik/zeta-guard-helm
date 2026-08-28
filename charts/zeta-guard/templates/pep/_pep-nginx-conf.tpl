{{- /* vim: set ft=helm: */ -}}
{{- define "zeta-guard.pep-nginx-conf" -}}
include main_modules.conf;
include main_common.conf;

worker_processes {{ $.Values.pepproxy.workerProcesses }};
worker_rlimit_nofile {{ $.Values.pepproxy.workerRlimitNofile }};

{{- with .Values.pepproxy.nginxConf }}
{{- /* deprecated raw `locations` and `proxyLocations` are mutually exclusive:
     mixing them breaks invariants both rely on (e.g. the derived WebSocket
     minion assumes proxyLocations describes ALL WebSocket paths, and duplicate
     location prefixes fail nginx startup). Migrate raw locations entirely. */}}
{{- if and .proxyLocations (ne (trim (default "" .locations)) "") }}
{{- fail "pepproxy.nginxConf: `locations` and `proxyLocations` are mutually exclusive — migrate the remaining raw `locations` to `proxyLocations` (raw `locations` is deprecated and scheduled for removal)" }}
{{- end }}

{{- if $.Values.pepproxyTracingEnabled }}
load_module modules/ngx_otel_module.so;
{{- end }}

error_log /dev/stdout;
{{- if $.Values.telemetryGatewayEnabled }}
error_log syslog:server={{ include "telemetryGateway.hostname" $ }}:54526;
{{- end }}
pid /tmp/nginx.pid;

{{- if or $.Values.global.httpProxy $.Values.global.httpsProxy $.Values.global.allProxy }}
env HTTP_PROXY;
env http_proxy;
env HTTPS_PROXY;
env https_proxy;
env ALL_PROXY;
env all_proxy;
{{- end }}
{{- if $.Values.global.noProxy }}
env NO_PROXY;
env no_proxy;
{{- end }}

events {
    worker_connections {{ $.Values.pepproxy.workerConnections }};
    multi_accept on;
    use epoll;
}

http {
    include http_common.conf;

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

    pep_revocation_url http://authserver/auth/realms/zeta-guard/zeta-guard-revocation;
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
    {{- if and $.Values.pepproxy.asl_hsm_key (not $.Values.pepproxy.hsmProxyAddr) }}
    {{- fail "pepproxy.asl_hsm_key requires pepproxy.hsmProxyAddr (ossl_hsm needs the HSM Proxy address)" }}
    {{- end }}
    pep_asl_signer_key "{{ $.Values.pepproxy.asl_hsm_key | default "/etc/nginx/signer_key.pem" }}";
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

    {{- with .proxyLocations }}

    ### Upstreams generated from pepproxy.nginxConf.proxyLocations
    {{- include "zeta-guard.pep-proxy-upstreams" (dict "root" $ "locations" .) | nindent 4 }}
    {{- end }}

    server {
        include server_common.conf;

        listen 8081 reuseport;
        {{- if $.Values.pepproxy.hsmProxyAddr }}
        listen 8443 ssl reuseport;
        ssl_certificate {{ $.Values.pepproxy.hsmTlsCert | quote }};
        ## NOTE: set HSM_PROXY_ADDR="https://hsm:50051" environment variable to use
        ## store:hsm with the ossl_hsm provider
        ssl_certificate_key {{ printf "store:hsm:%s" $.Values.pepproxy.hsmTlsKeyId | quote }};
        {{- end }}

        {{- $.Values.pepproxy.tlsConfig | nindent 8 }}

        server_name pep-proxy-svc;

        # A_25669-01 / A_28439: bind the PEP-set headers once for the whole server
        # (strip client-supplied credentials and ZETA-* headers, Forwarded per RFC 7239).
        # Locations inherit this automatically. Exception: nginx proxy_set_header inheritance is
        # NOT additive — a location with its own proxy_set_header (e.g. a WebSocket upgrade or the
        # OpenShift cookie strip in /pep/) does not inherit the strips and must re-include
        # `proxy_headers.conf;` itself.
        include proxy_headers.conf;

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

            gzip on;
            default_type application/json;
            alias /srv/.well-known/;
            autoindex off;
            location = /.well-known/oauth-authorization-server {
                proxy_pass http://authserver/auth/realms/zeta-guard/.well-known/zeta-guard-well-known;
                proxy_http_version 1.1;
            }
            {{- if $.Values.notificationService.enabled }}
            # A_29979/A_28436: NS's own protected-resource doc, on its resource subpath.
            {{- $nsSubpath := include "zeta-guard.ns-well-known-subpath" $ }}
            location = /.well-known/oauth-protected-resource/{{ $nsSubpath }} {
                alias /srv/.well-known/resources/{{ $nsSubpath }};
            }
            {{- end }}
        }

        {{- if $.Values.authserver.adminHostname }}
        # Block public access to Keycloak Admin REST API and Admin Console. Only
        # /auth/admin is routed here (ingress-pep.yaml); every other /auth/* path goes
        # straight to the authserver via the zeta-guard-auth minion and never reaches the
        # PEP. `return` runs in the rewrite phase, so this answers before the PEP access
        # check and before the server-level "deny all" that asl_enabled adds.
        location ~ ^/auth/admin {
            return 403;
        }
        {{- end }}
        {{- with .proxyLocations }}

        ### Locations generated from pepproxy.nginxConf.proxyLocations
        {{- include "zeta-guard.pep-proxy-locations" (dict "root" $ "locations" .) | nindent 8 }}
        {{- end }}
        {{- if $.Values.notificationService.enabled }}
        {{- $nsAudience := printf "%s%s" $.Values.pepproxy.wellKnownBase $.Values.notificationService.wellKnownResourceSuffix }}
        # A_29979: bundled notification-service (push facade). /push/v1 is the FdV
        # API basePath; only scope-table operations are exposed, the rest denied below.
        # A_29979/A_29976: the NS is a distinct resource server, so each location
        # overrides pep_require_aud with the NS resource identifier ($nsAudience, =
        # the well-known `resource`); a Fachdienst-scoped token MUST NOT be accepted.
        # DPoP/exp/nbf/iat/iss stay covered by the global pep config; scope is per
        # location. A_29978 user-object binding stays with the NS (ZETA-User-Info).
        # NS well-known advertises zeta_asl_use: not_supported, so each location uses
        # "satisfy all; allow all;" to override asl_enabled's server-wide "deny all".
        # Token/DPoP/scope enforcement stays in effect.
        # PoPP off per location (pep_require_popp off): an insured managing her own
        # push registrations has no provider visit to prove.
        location = /push/v1/pushers {
            satisfy all;
            allow all;
            limit_except GET { deny all; }
            pep_require_aud {{ $nsAudience }};
            pep_require_popp off;
            pep_require_scope "notification.pusher.read";
            proxy_pass http://notification-service-fdv:8080/pushers;
            proxy_http_version 1.1;
        }
        location = /push/v1/pushers/set {
            satisfy all;
            allow all;
            limit_except POST { deny all; }
            pep_require_aud {{ $nsAudience }};
            pep_require_popp off;
            pep_require_scope "notification.pusher.write";
            proxy_pass http://notification-service-fdv:8080/pushers/set;
            proxy_http_version 1.1;
        }
        location = /push/v1/channels {
            satisfy all;
            allow all;
            limit_except GET { deny all; }
            pep_require_aud {{ $nsAudience }};
            pep_require_popp off;
            pep_require_scope "notification.channel.read";
            proxy_pass http://notification-service-fdv:8080/channels;
            proxy_http_version 1.1;
        }
        # GET/POST /channels/{pushkey} need different scopes on one path; pep_require_scope
        # is one set per location, so dispatch by method via the error_page-redirect trick.
        location ~ ^/push/v1/channels/([^/]+)$ {
            satisfy all;
            allow all;
            pep_require_popp off;
            set $ns_pushkey $1;
            error_page 418 = @notification_channel_pushkey_get;
            error_page 421 = @notification_channel_pushkey_post;
            if ($request_method = GET) { return 418; }
            if ($request_method = POST) { return 421; }
            return 405;
        }
        # Map /push/v1 to the upstream path via variable proxy_pass ($is_args$args
        # re-appends the query a variable URI would drop). Leaves $uri untouched, so
        # the DPoP htu check still sees the original /push/v1/... the client signed —
        # a `rewrite ... break` would mutate $uri first and break the htu comparison.
        location @notification_channel_pushkey_get {
            satisfy all;
            allow all;
            pep_require_aud {{ $nsAudience }};
            pep_require_popp off;
            pep_require_scope "notification.channel.read";
            proxy_pass http://notification-service-fdv:8080/channels/$ns_pushkey$is_args$args;
            proxy_http_version 1.1;
        }
        location @notification_channel_pushkey_post {
            satisfy all;
            allow all;
            pep_require_aud {{ $nsAudience }};
            pep_require_popp off;
            pep_require_scope "notification.channel.write";
            proxy_pass http://notification-service-fdv:8080/channels/$ns_pushkey$is_args$args;
            proxy_http_version 1.1;
        }
        # A_29974: route is always present; when history is off the scope isn't issued so
        # this 403s, and the NS 404/501s (defence in depth).
        location /push/v1/history/ {
            satisfy all;
            allow all;
            limit_except GET { deny all; }
            pep_require_aud {{ $nsAudience }};
            pep_require_popp off;
            pep_require_scope "notification.history.read";
            proxy_pass http://notification-service-fdv:8080/history/;
            proxy_http_version 1.1;
        }
        # Deny everything else under /push/v1/ so only the routes above are reachable
        # (explicit 403 regardless of asl_enabled).
        location /push/v1/ {
            satisfy all;
            allow all;
            pep_require_popp off;
            return 403;
        }
        {{- end }}
        {{- if and (ne (trim (default "" .locations)) "") (contains "fachdienstUrl" .locations) (eq (default "" .fachdienstUrl) "") }}
        {{- fail "pepproxy.nginxConf: `locations` references `fachdienstUrl` but it is empty — either set fachdienstUrl or migrate to proxyLocations" }}
        {{- end }}
        {{- tpl .locations $ | nindent 8 }}
    }

    {{- if $.Values.pepproxyTracingEnabled }}
    otel_exporter {
        endpoint {{ include "telemetryGateway.hostname" $ }}:4317;
    }
    otel_trace on;
    otel_trace_context propagate;
    otel_resource_attr "service.version" "{{ $.Chart.Version }}";
    otel_service_name "{{ include "pep-proxy.otel-service-name" $ }}";
    otel_span_attr http.request.method_original $request_method;
    otel_span_attr client.address               $zeta_client_address;
    otel_span_attr app.installation.id          $zeta_client_id;
    otel_span_attr is_asl                       $zeta_is_asl;
    otel_span_attr product.id                   $zeta_product_id;
    otel_span_attr product.version              $zeta_product_version;
    otel_span_attr profession.oid               $zeta_profession_oid;

    {{- end }}

    server {
        listen 8080 reuseport;

        location = /status {
            {{- if $.Values.pepproxyTracingEnabled }}
            otel_trace off;
            {{- end }}
            pep off;
            access_log off;
            stub_status;
        }
    }
}

{{- end }}
{{- end -}}
