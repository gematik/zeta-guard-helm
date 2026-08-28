# ZETA push-gateway Helm Chart

`charts/push-gateway` is a thin, local/demo-only deployment of gematik's Push Gateway
(upstream repo: `gematik/push-gateway`). It serves as a dispatch target for the bundled
Notification Service, which requires a configured Push Gateway allowlist to start.

See [How to configure the Notification Service](../../docs/how-to_guides/How_to_configure_notification_service.md)
for how to enable it and wire it up in a ZETA Guard deployment.
