# Introduction

The Tiger proxy is a component of the Tiger test framework developed by gematik (https://github.com/gematik/app-Tiger).

In this project a standalone Tiger proxy is deployed as a reverse proxy to intercept, decrypt and analyse requests that are routed through the proxy
to enable the evaluation of exhaustive component and integration tests with deep insights on the wire.

# Setup

The Tiger proxy is deployed in standalone mode. Requests are routed through a proxy port (`tiger-proxy.proxyConfig.proxyPort`) while certain management tasks are available through a dedicated admin port (`tiger-proxy.proxyConfig.adminPort`).

To route requests through the proxy, the routing targets of the central `Ingress` ressource are modified depending on the `zeta-guard.routeViaTigerProxy` flag.

The Tiger proxy itself defines routes (`tiger-proxy.proxyConfig.proxyRoutes[]`) that are responsible for forwarding incoming requests to the correct backend service.
