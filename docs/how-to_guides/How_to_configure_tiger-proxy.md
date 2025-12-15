# How to configure and use the Tiger proxy?

> **Warning – insecure components**
> Tiger Testsuite and Tiger Proxy may contain critical security flaws. Do **not** run them in
> production or any security-sensitive environment. Remove the chart or keep the chart disabled unless you are testing
> in an isolated sandbox:
>
> ```
> tags:
>   tiger-proxy: false
> ```


## Activate routing via tiger proxy

Set the following values in the `values.yaml` file for the respective environment to activate routing via Tiger proxy:

```
tags:
  tiger-proxy: true

tiger-proxy:
  proxyConfig:
    proxyRoutes:
      - from: /testfachdienst
        to: https://testfachdienst:443
      - from: /auth
        to: http://authserver/auth
      - from: /proxy
        to: http://testdriver/proxy
      - from: /
        to: http://pep-proxy-svc

zeta-guard:
  routeViaTigerProxy: true
  pepproxy:
    nginxConf:
      fachdienstUrl: https://tiger-proxy:80/testfachdienst
```

After setting these values the Tiger proxy chart will be deployed when running `make deploy stage=<target-stage>`. 

## Deactivate routing via tiger proxy

Set the following values in the `values.yaml` file for the respective environment to deactivate routing via Tiger proxy:

```
tags:
  tiger-proxy: false

tiger-proxy: {}

zeta-guard:
  routeViaTigerProxy: false
  pepproxy:
    nginxConf:
      fachdienstUrl: http://testfachdienst:443
```

After setting these values the Tiger proxy chart will be ignored when running `make deploy stage=<target-stage>`. 


## Enable TLS for the testfachdienst route

When `testfachdienst` is configured to serve HTTPS (for example by setting `SERVER_SSL_ENABLED=true`), the Tiger proxy must
both forward traffic via HTTPS to the backend and present its own certificate to the callers. Configure the TLS support
in the chart values:

```
testfachdienst:
  env:
    - name: SERVER_SSL_ENABLED
      value: "true"

tiger-proxy:
  proxyConfig:
    proxyRoutes:
      - from: /testfachdienst
        to: https://testfachdienst:443
      # … other routes …
    tls:
      domainName: tiger-proxy
```

The `domainName` must match the hostname that clients use when calling the proxy. In the local profiles the service is
still exposed on port 80, so refer to it as `https://tiger-proxy:80/testfachdienst` from the PEP proxy configuration. The
Tiger proxy will generate a self-signed CA and per-host certificates on the fly (see section 4.4 of the Tiger
documentation), so clients either need to trust that CA or disable certificate verification for this upstream.
