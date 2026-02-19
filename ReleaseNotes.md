<img align="right" width="250" height="47" src="docs/img/Gematik_Logo_Flag.png"/> <br/>

# Release Notes ZETA Guard Helm Charts


## Release 0.3.2

### changed
- authserver-version

## Release 0.3.1

### added
- websocket support

## Release 0.3.0

### added:
- added support for postgres operator by documentation and makefile; also in
  local test setup
- telemetry-gateway can redact known kinds of secrets and personal information
  from logs, metrics and traces
- Mergeable Ingress (F5 NIC: master + minions)

### changed:
- Helm 4 required; Kubernetes >= 1.25;
- TLS defaults hardened (protocols, ciphers, HSTS)
- **BREAKING CHANGE**. We changed the ingress to F5 nginx-ingress NIC mergeable (master + minions).
  If you were using the original community ingress-nginx from the ZETA umbrella chart,
  delete the cluster-scoped IngressClass and ValidatingWebhookConfiguration, and remove the
  associated Deployment/Services/Lease in your target namespace before deploying the new
  version. For example (replace NAMESPACE and STAGE):
  ```shell
  # cluster-scoped admission webhook (community ingress-nginx)
  kubectl delete validatingwebhookconfiguration zeta-testenv-STAGE-ingress-nginx-admission --ignore-not-found

  # namespaced community controller objects
  kubectl -n NAMESPACE delete deploy zeta-testenv-STAGE-ingress-nginx-controller --ignore-not-found
  kubectl -n NAMESPACE delete svc zeta-testenv-STAGE-ingress-nginx-controller --ignore-not-found
  kubectl -n NAMESPACE delete svc zeta-testenv-STAGE-ingress-nginx-controller-admission --ignore-not-found
  kubectl -n NAMESPACE delete lease zeta-testenv-STAGE-ingress-nginx-leader --ignore-not-found

  # cluster-scoped IngressClass used by the old controller
  kubectl delete ingressclass nginx-STAGE --ignore-not-found
  ```
  If Helm fails with lease ownership/validation errors during upgrade:
  - Adopt the existing Lease into the release:
    ```shell
    kubectl -n NAMESPACE annotate lease zeta-testenv-STAGE-nginx-ingress-leader-election meta.helm.sh/release-name=zeta-testenv-STAGE --overwrite
    kubectl -n NAMESPACE annotate lease zeta-testenv-STAGE-nginx-ingress-leader-election meta.helm.sh/release-namespace=NAMESPACE --overwrite
    kubectl -n NAMESPACE label lease zeta-testenv-STAGE-nginx-ingress-leader-election app.kubernetes.io/managed-by=Helm --overwrite
    ```
  - Or delete the Lease and redeploy:
    ```shell
    kubectl -n NAMESPACE delete lease zeta-testenv-STAGE-nginx-ingress-leader-election
    ```

  Notes:
  - Stray community ingress-nginx ValidatingWebhookConfigurations from other environments can block Ingress
    applies cluster-wide if their admission Service has no endpoints. Remove unused
    `*-ingress-nginx-admission` webhooks (or temporarily set `failurePolicy: Ignore`) before deploying.
  - hardened security context for all components

## Release 0.2.8

### changed:
- authserver and testdriver/exauthsim now have separate keystores/truststores.
  This chart now includes an RU based truststore for the authserver. For the
  testdriver/exauthsim you still need to bring your own cert&key. 
- The values for the SMCB keystore have changed slightly. Now they are
  `smcb_keystore.keystore` and `smcb_keystore.password` with the same semantics.
  No changes are needed when using the makefile for the test setup.

## Release 0.2.7

### added:
- ability to configure external DBs. See helm values authserverDb.* in zeta-guard subchart
- improvements for better compliance with some kubernetes security policies

### changed:
- Makefile: streamlined stage/namespace/values selection; safer templating; clearer help
- Enforce admin-password of Authserver on initial deployment

## Release 0.2.6

### added:
- config for ASL test mode
- improved Betriebsdatenlieferung

### changed:
- updated versions of several subcomponents

## Release 0.2.5

### changed:
- fix missing opa service account
- fix popp token config

## Release 0.2.4

### added:
- missing file(s) for local deployments

### changed:
- minor doc improvements
- updated individual components to their newes versions
- functional userdata and clientdata headers (beware clientdata schema is still subject to change)

## Release 0.2.0

### added:
- bundling functionality of milestone 2 incl client registration, smcb token exchange
- public release of test setup

## Release 0.1.3

### added:
- Helm chart for the prototype of ZETA Guard added
