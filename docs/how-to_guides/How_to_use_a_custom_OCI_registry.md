# How to Use a Custom OCI Registry

By default, the ZETA Guard Helm chart references images on the upstream
registries. For production use you should pull all images — including the
provisioning data image that the provisioning processor downloads at
runtime — from a buffering registry under your own control, for availability
and to avoid egress traffic.

This guide explains what the provisioning processor and the provisioning data
image are, how to point all images at your own registry, how to mirror the
signed provisioning data image correctly and how to give the init
container a CA certificate for a registry with an internal CA.

---

## Background: provisioning processor and provisioning data image

The **provisioning processor** is an init container that runs on every start of
the ZETA Guard pods (authserver, PEP proxy, OPA, OPA simulation). It is part of
the Helm chart and is configured via `provisioningProcessor.image.*`. For its
resource and security-context configuration see
[How to configure ZETA Guard Authserver](How_to_configure_authserver.md).

The **provisioning data image** (configured via
`provisioningProcessor.provisioningContainer`) is a separate OCI image that the
provisioning processor downloads from the registry at runtime and verifies
against its cosign signature. It contains the cryptographic material (trust
roots, certificate chains) that the ZETA Guard services need — e.g., the SMC-B
trust anchors extracted from the TSL.

## Pointing images at your own registry

Control the image sources through Helm values:

* General configuration
    * `global.registry_host` — registry host, e.g.
      `my.registry.corp.internal:443`
    * `global.imagePullSecrets` (optional) — list of image pull secrets in
      Kubernetes syntax.
      Required when the images are protected by authentication. See
      [How to create a docker-registry type secret](How_to_create_a_docker_registry_secret.md).
* Authorization server
    * `authserver.image.repository` — authserver image path in the registry
    * `authserver.image.tag` — image tag to use
    * `authserver.image.digest` — optional image digest; overrides the tag when
      set
    * `authserver.imagePullPolicy` — defaults to `Always`
    * `authserver.imagePullSecrets` (optional) — like `global.imagePullSecrets`
* PEP proxy
    * `pepproxy.image.repository` — PEP proxy image path in the registry
    * `pepproxy.image.tag` — image tag to use
    * `pepproxy.image.digest` — optional image digest; overrides the tag when
      set
    * `pepproxy.imagePullPolicy` — defaults to `Always`
    * `pepproxy.imagePullSecrets` (optional) — like `global.imagePullSecrets`
* Provisioning processor (init container)
    * `provisioningProcessor.image.repository` — provisioning processor image
      path
    * `provisioningProcessor.image.tag` — image tag to use
    * `provisioningProcessor.provisioningContainer` — OCI reference of the
      provisioning data image (pulled at runtime by the init container, see
      below)
    * `provisioningProcessor.provisioningContainerCaSecretRef` — registry CA
      certificate as a Secret reference (see below)
    * `provisioningProcessor.provisioningContainerCaConfigMapRef` — registry CA
      certificate as a ConfigMap reference, alternative to the Secret reference
      (see below)
    * `provisioningProcessor.extraEnv` / `extraVolumes` / `extraVolumeMounts`
      (optional) — generic wiring of arbitrary sources into the init container
      (see below)
  * `provisioningProcessor.registryCredentialsSecretRef` (optional) — username
    and token for registries that do not allow anonymous access (see below)
* OPA (policy engine)
    * `opa.image.repository` — OPA image path in the registry
    * `opa.image.tag` — image tag to use
    * `opa.image.digest` — optional image digest; overrides the tag when set
    * `opa.imagePullPolicy` — defaults to `IfNotPresent`
    * `opa.imagePullSecrets` (optional) — like `global.imagePullSecrets`
    * OPA simulation uses the same image
* Infinispan (external cache, optional)
    * `global.infinispanExternal.image.repository` — Infinispan image path in
      the registry
    * `global.infinispanExternal.image.tag` — image tag to use
    * `global.infinispanExternal.imagePullPolicy` — defaults to `IfNotPresent`
    * `global.infinispanExternal.imagePullSecrets` (optional) — like
      `global.imagePullSecrets`
* Keychain generator (only when DB encryption for VAU-based applications is
  enabled)
    * `authserver.dbEnc.keychainGenerator.image.repository` — image path in the
      registry
    * `authserver.dbEnc.keychainGenerator.image.tag` — image tag to use
    * `authserver.dbEnc.keychainGenerator.image.digest` — optional image digest;
      overrides the tag when set

## Mirroring the provisioning data image

The provisioning data image (`zeta-guard-provisioning`) is pulled by the init
container at runtime and verified against its cosign signature. cosign stores
signatures as separate OCI artifacts under a `.sig` tag in the same registry
(e.g.
`europe-west3-docker.pkg.dev/.../zeta-guard-provisioning:sha256-<digest>.sig`).

When mirroring, you therefore have to transfer both the image tag and the
matching `.sig` tag into the target registry. There are several options:

- **`cosign save`/`load`** (recommended): transfers the image and all signature
  artifacts in one step, without needing to know the `.sig` tag explicitly.
- **`docker pull`/`push`**: possible, but requires explicitly mirroring the
  `.sig` tag in addition to the image tag.
- **`skopeo copy`**: useful especially in OpenShift environments. Whether `.sig`
  tags are transferred automatically depends on the registry backend — with
  Red Hat Quay the `.sig` tags must be specified explicitly. Always verify the
  tooling and registry product you use.

### Transferring the image with its signature

On a machine with access to the gematik registry:

```bash
cosign save \
  --dir /tmp/zeta-guard-provisioning-cosign \
  europe-west3-docker.pkg.dev/gematik-pt-zeta-test/zeta-provisioning/zeta-guard-provisioning:latest

tar -czf zeta-guard-provisioning-cosign.tar.gz \
  -C /tmp zeta-guard-provisioning-cosign
```

Transfer the tarball to a system that has access to the internal registry (e.g.
a jump host in the target network) and run there:

```bash
tar -xzf zeta-guard-provisioning-cosign.tar.gz -C /tmp

cosign load \
  --dir /tmp/zeta-guard-provisioning-cosign \
  my.registry.corp.internal/zeta-guard-provisioning:latest

# Temporary files can be removed afterwards:
rm -rf /tmp/zeta-guard-provisioning-cosign zeta-guard-provisioning-cosign.tar.gz
```

`cosign load` transfers the image and its signature into the target registry.

## CA certificate for the registry

When the registry uses a certificate issued by a Certification Authority (CA)
that is not publicly trusted (e.g., an internal CA), the CA certificate must be
provided to the init container. The certificate is mounted as a file into the
init container at `/var/registry-ca/ca.crt`, and the init container is told
about it via the `PROVISIONING_CONTAINER_REGISTRY_CA_FILE` environment variable.
Mounting it as a file (rather than passing it as an environment variable) avoids
the `ARG_MAX` kernel limit, which can be exceeded by large certificate chains.

The same reference also supplies the CA to the `opa` and `opa-simulation`
containers, which need it at runtime to pull the OPA policy bundle in bundle
mode (`opa.bundle.enabled: true`). The certificate is mounted at the same path
and rendered into the OPA configuration as
`services.<opa.bundle.serviceName>.tls.ca_cert`, together with
`system_ca_required: true` — the CA is *appended* to the container image's
system
trust store, so a publicly trusted registry keeps working. Without it, OPA logs
`x509: certificate signed by unknown authority` and keeps running with no policy
bundle; see `opa.bundleHealthCheck` in
[the OPA reference](../reference/OPA.md) to make that failure visible.

> **Provide a full CA bundle, not just your own CA.** One reference serves two
> consumers, and they treat the file differently. OPA *appends* it to the system
> trust store (`system_ca_required: true`), but the init container passes it to
> `cosign` as the **only** trust anchor. So if the file contains just your
> internal CA while the provisioning data image is pulled from a publicly
> trusted registry, the init container fails with
> `Error: signed entity: Get "https://…/v2/": tls: failed to verify certificate:
> x509: certificate signed by unknown authority` and the pod never starts.
> Concatenate your CA with the public root bundle (e.g. your distribution's
> `ca-certificates.crt`) or mirror the provisioning data image into the same
> private registry so that one CA covers both pulls.

There are three ways to provide it. The Secret and ConfigMap references are
mutually exclusive — if both are set, the Secret reference takes precedence.

### Option A — from a Secret

```bash
kubectl create secret generic registry-ca \
  --from-file=ca.crt=/path/to/ca.pem
```

```yaml
zeta-guard:
  provisioningProcessor:
    provisioningContainerCaSecretRef:
      name: registry-ca
      key: ca.crt
```

### Option B — from a ConfigMap

Because the public parts of a CA certificate are not secret, the certificate can
be mounted from a ConfigMap instead of a Secret. This is particularly useful
on OpenShift: the standard configuring a custom PKI mechanism publishes the
cluster-wide CA bundle as a ConfigMap, which avoids maintaining CA bundles by
hand.

```bash
kubectl create configmap zeta-guard-openshift-ca-bundle \
  --from-file=ca-bundle.crt=/path/to/ca-bundle.pem
```

```yaml
zeta-guard:
  provisioningProcessor:
    provisioningContainerCaConfigMapRef:
      name: zeta-guard-openshift-ca-bundle
      key: ca-bundle.crt
```

### Option C — generic wiring via `extraVolumes`/`extraVolumeMounts`/`extraEnv`

If the CA certificate (or other material) should come from a different source
(projected volumes, CSI, ...), the wiring can be done fully manually with
generic values on the init container. You provide the volume, the mount and the
`PROVISIONING_CONTAINER_REGISTRY_CA_FILE` environment variable yourself:

```yaml
zeta-guard:
  provisioningProcessor:
    extraEnv:
      - name: PROVISIONING_CONTAINER_REGISTRY_CA_FILE
        value: /var/custom-ca/ca.crt
    extraVolumes:
      - name: custom-ca
        configMap:
          name: my-ca-bundle
    extraVolumeMounts:
      - name: custom-ca
        mountPath: /var/custom-ca
        readOnly: true
```

This option covers the init container only — it does **not** give OPA the CA for
policy bundle pulls. If the OPA bundle comes from a registry with a private CA,
use Option A or Option B.

## Registry credentials (username / token)

Many enterprise registries do not allow anonymous access. To pull the
provisioning data image from such a registry, provide a username and a
token/password. The init container performs a `cosign login` with these
credentials before fetching the image, via the environment variables
`PROVISIONING_CONTAINER_REGISTRY_USERNAME` and
`PROVISIONING_CONTAINER_REGISTRY_TOKEN`.

The credentials come from an existing Kubernetes Secret, which is referenced by
`provisioningProcessor.registryCredentialsSecretRef`. In production the Secret
is typically created from a SealedSecret so the token is never stored in plain
text.

```bash
kubectl create secret generic registry-credentials \
  --from-literal=username='<registry-user>' \
  --from-literal=token='<registry-token>'
```

```yaml
zeta-guard:
  provisioningProcessor:
    registryCredentialsSecretRef:
      name: registry-credentials
      usernameKey: username   # default: username
      tokenKey: token         # default: token
```

`usernameKey` and `tokenKey` are optional and default to `username` and `token`
respectively — set them if the Secret uses different key names. Leave
`registryCredentialsSecretRef` unset for registries that allow anonymous access.

## Related

- To route the init container's registry egress through a forward proxy (or to
  bypass it via `global.noProxy`), see
  [How to configure a forward proxy](How_to_configure_forward_proxy.md).
- When egress NetworkPolicies are enabled, the init container needs egress to
  the artifact registry; see
  [How to configure Egress NetworkPolicies](How_to_configure_NetworkPolicies.md).
