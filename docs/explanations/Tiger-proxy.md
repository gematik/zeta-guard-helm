# Introduction

The Tiger proxy is a component of the Tiger test framework developed by gematik (https://github.com/gematik/app-Tiger).

In this project a standalone Tiger proxy is deployed as a reverse proxy to intercept, decrypt and analyse requests that are routed through the proxy
to enable the evaluation of exhaustive component and integration tests with deep insights on the wire.

# Setup

The Tiger proxy is deployed in standalone mode. Requests are routed through a proxy port (`tiger-proxy.proxyConfig.proxyPort`) while certain management tasks are available through a dedicated admin port (`tiger-proxy.proxyConfig.adminPort`).

To route requests through the proxy, the routing targets of the central `Ingress` ressource are modified depending on the `zeta-guard.routeViaTigerProxy` flag.

The Tiger proxy itself defines routes (`tiger-proxy.proxyConfig.proxyRoutes[]`) that are responsible for forwarding incoming requests to the correct backend service.

Telemetry traffic follows the same routing model, but it uses a dedicated OTLP HTTP entrypoint on `tiger-proxy:4138`.
That entrypoint forwards requests to the Tiger route `/telemetry/gateway`, which must be present in
`tiger-proxy.proxyConfig.proxyRoutes[]`. Whether telemetry goes through Tiger or directly to the collector is therefore
controlled by the exporter destination (`http://tiger-proxy:4138` versus the real collector endpoint), not by
`zeta-guard.routeViaTigerProxy`.

When PoPP metadata is served through Tiger Proxy, the proxy route list must also expose the externally visible
federation and key endpoints that the PEP stack relies on: `/.well-known/openid-federation`,
`/.well-known/signed-jwks`, and the `/popp` base path. In the default setup these routes are
forwarded to the `popp-statics` Service from the `popp-mocks` chart.
