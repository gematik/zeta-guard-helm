# TLS Hardening (Controller Defaults)

When using the bundled F5 NGINX Ingress Controller (NIC), the controller ConfigMap enforces
strict TLS settings by default for all Ingress traffic managed by the controller.

- Protocols: TLS 1.2 and TLS 1.3 only (`ssl-protocols: "TLSv1.2 TLSv1.3"`)
- Ciphers (TLS 1.2): AEAD cipher suites (AES‑GCM)
- Ciphersuites (TLS 1.3): AES‑GCM
- ECDH curves: `prime256v1:secp384r1:brainpoolP256r1:brainpoolP384r1`
- Sessions: cache disabled, tickets enabled, timeout 5m
- OCSP stapling: disabled
- Server cipher preference: off

## Verification
- With curl (OpenSSL):
  - `curl -vkI --tls-max 1.1 https://<host>/...` → should fail
  - `curl -vkI --tls-max 1.2 https://<host>/...` → should succeed (TLS 1.2)
  - `curl -vkI --tls-max 1.3 https://<host>/...` → should succeed (TLS 1.3)
- With OpenSSL s_client:
  - `openssl s_client -connect <host>:443 -servername <host> -tls1_1` → fail
  - `openssl s_client -connect <host>:443 -servername <host> -tls1_2` → succeed
  - `openssl s_client -connect <host>:443 -servername <host> -tls1_3` → succeed

Notes
- These settings are applied at the NIC controller layer and do not require per‑Ingress overrides.
- Ensure your deployment uses the NIC’s ConfigMap entries to enforce these defaults.
