# SBOM of the chart tarballs

Every published chart tarball contains `sbom.cdx.json`, a CycloneDX 1.6 inventory of the container images the
chart deploys (`zeta-guard`: its own images; `zeta-testenv`: additionally the test components, with the guard SBOM
nested under `charts/zeta-guard/`). The files are generated in the build pipeline from the rendered chart, never
maintained by hand.

Structure, purl scheme and the meaning of the `zeta:*` properties are documented in the user manual:
[SBOM der ZETA-Guard-Lieferung](https://github.com/gematik/zeta/blob/main/docs/user-manual/Referenzen/SBOM.md).
Each SBOM links there from its root component (`externalReferences`, type `documentation`).
