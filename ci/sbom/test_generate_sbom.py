"""Unit tests for generate_sbom.py — `make sbom-test`.

No network, no helm: the pure functions (parse, collect, merge, build) run on small hand-written
inputs. Rendering and digest lookup are covered by the pipeline (`make sbom` + `make sbom-validate`).
One test class per function, in the order the generator uses them.
"""
import json
import unittest

import generate_sbom as g

GAR = "europe-west3-docker.pkg.dev/gematik-pt-zeta-prod/zeta-dcr"
DIGEST = "sha256:" + "ab" * 32


class ParseImage(unittest.TestCase):
    """Splitting a reference into (repo, name, tag, digest). A registry port looks like a tag
    separator but belongs to the repo; a tag may not contain "/", which tells them apart."""

    def test_tag(self):
        self.assertEqual(g.parse_image(f"{GAR}/ngx_pep:1.3.3"), (f"{GAR}/ngx_pep", "ngx_pep", "1.3.3", ""))

    def test_digest_only(self):
        self.assertEqual(g.parse_image(f"python@{DIGEST}"), ("python", "python", None, DIGEST))

    def test_tag_and_digest(self):
        self.assertEqual(g.parse_image(f"busybox:1.37.0@{DIGEST}"), ("busybox", "busybox", "1.37.0", DIGEST))

    def test_registry_port_without_tag(self):
        self.assertEqual(g.parse_image("reg.example:443/zeta/img"), ("reg.example:443/zeta/img", "img", None, ""))

    def test_registry_port_with_tag(self):
        self.assertEqual(g.parse_image("reg.example:443/zeta/img:1.0"), ("reg.example:443/zeta/img", "img", "1.0", ""))

    def test_docker_hub_shorthand(self):
        self.assertEqual(g.parse_image("google/cloud-sdk:549.0.0"), ("google/cloud-sdk", "cloud-sdk", "549.0.0", ""))


class LookupRef(unittest.TestCase):
    """skopeo refuses 'repo:tag@digest'; pinned images are looked up as 'repo@digest'."""

    def test_pinned_drops_tag(self):
        self.assertEqual(g.lookup_ref(f"busybox:1.37.0@{DIGEST}"), f"busybox@{DIGEST}")

    def test_pinned_keeps_registry_port(self):
        self.assertEqual(g.lookup_ref(f"reg:443/x/img:1.0@{DIGEST}"), f"reg:443/x/img@{DIGEST}")

    def test_unpinned_unchanged(self):
        self.assertEqual(g.lookup_ref("reg:443/x/img:1.0"), "reg:443/x/img:1.0")


class FallbackRefs(unittest.TestCase):
    """fallback_refs(): where to look when the referenced registry does not have the image yet."""

    FALLBACK = {f"{GAR}/ngx_pep": "registry.example:443/zeta/zeta-guard/ngx_pep"}

    def test_tagged_image_mapped_to_source_repo(self):
        self.assertEqual(g.fallback_refs(f"{GAR}/ngx_pep:1.3.3", self.FALLBACK),
                         ["registry.example:443/zeta/zeta-guard/ngx_pep:1.3.3"])

    def test_pinned_image_is_looked_up_by_digest(self):
        self.assertEqual(g.fallback_refs(f"{GAR}/ngx_pep:1.3.3@{DIGEST}", self.FALLBACK),
                         [f"registry.example:443/zeta/zeta-guard/ngx_pep@{DIGEST}"])

    def test_unmapped_image_has_no_fallback(self):
        self.assertEqual(g.fallback_refs("alpine:3.17", self.FALLBACK), [])
        self.assertEqual(g.fallback_refs(f"{GAR}/ngx_pep:1.3.3", {}), [])


class DigestOf(unittest.TestCase):
    """digest_of(): registry lookup with fallback, skopeo replaced by a fake manifest_digest()."""

    FALLBACK = {f"{GAR}/ngx_pep": "src.example/ngx_pep"}

    def setUp(self):
        self.calls = []
        self.registry = {}  # ref -> digest the fake registry "has"
        self._orig = g.manifest_digest
        g.manifest_digest = lambda ref: (self.calls.append(ref), self.registry.get(ref, ""))[1]

    def tearDown(self):
        g.manifest_digest = self._orig

    def test_not_resolving_returns_pinned_only(self):
        self.assertEqual(g.digest_of(f"{GAR}/ngx_pep:1.3.3", False, self.FALLBACK), ("", None, ""))
        self.assertEqual(g.digest_of(f"python@{DIGEST}", False), (DIGEST, None, ""))
        self.assertEqual(self.calls, [])  # no registry access at all

    def test_found_in_referenced_registry(self):
        self.registry[f"{GAR}/ngx_pep:1.3.3"] = DIGEST
        self.assertEqual(g.digest_of(f"{GAR}/ngx_pep:1.3.3", True, self.FALLBACK), (DIGEST, True, "referenced"))
        self.assertEqual(self.calls, [f"{GAR}/ngx_pep:1.3.3"])  # fallback not consulted

    def test_missing_but_resolved_from_fallback(self):
        # not promoted yet: digest comes from the source repo, found stays False
        self.registry["src.example/ngx_pep:1.3.3"] = DIGEST
        self.assertEqual(g.digest_of(f"{GAR}/ngx_pep:1.3.3", True, self.FALLBACK), (DIGEST, False, "fallback"))
        self.assertEqual(self.calls, [f"{GAR}/ngx_pep:1.3.3", "src.example/ngx_pep:1.3.3"])

    def test_missing_everywhere(self):
        self.assertEqual(g.digest_of(f"{GAR}/ngx_pep:1.3.3", True, self.FALLBACK), ("", False, ""))

    def test_pinned_digest_is_kept_and_only_verified(self):
        self.registry["src.example/ngx_pep@" + DIGEST] = "sha256:" + "cd" * 32  # would differ, must be ignored
        self.assertEqual(g.digest_of(f"{GAR}/ngx_pep:1.3.3@{DIGEST}", True, self.FALLBACK), (DIGEST, False, "fallback"))

    def test_pinned_digest_not_found_anywhere_stays_unverified(self):
        self.assertEqual(g.digest_of(f"python@{DIGEST}", True, {}), (DIGEST, False, ""))


def doc(kind, name, **spec):
    """One rendered manifest as a JSON line (the shape `yq -o=json -I=0` produces)."""
    return json.dumps({"apiVersion": "v1", "kind": kind, "metadata": {"name": name}, "spec": spec})


# Synthetic render: Deployment with sidecar + init container, CronJob (pod spec nested deeper),
# CNPG Cluster (image in spec.imageName), Service without images, ConfigMap whose "containers"
# is not a list, trailing empty line.
RENDER = "\n".join([
    doc("Deployment", "authserver", template={"spec": {
        "containers": [{"name": "kc", "image": f"{GAR}/keycloak-zeta:1.3.2"},
                       {"name": "pp", "image": f"{GAR}/provisioning-processor:1.3.2"}],
        "initContainers": [{"name": "init", "image": f"{GAR}/keychain-generator:2.0.4"}]}}),
    doc("CronJob", "opa-rollout", jobTemplate={"spec": {"template": {"spec": {
        "containers": [{"name": "pp", "image": f"{GAR}/provisioning-processor:1.3.2"}]}}}}),
    doc("Cluster", "keycloak-db", imageName=f"{GAR}/postgres:17.11-standard-trixie"),
    doc("Service", "authserver", ports=[{"port": 8080}]),
    doc("ConfigMap", "cfg", containers="not-a-list"),
    "",
])


class CollectImages(unittest.TestCase):
    """Images and their workloads (Kind/name) from the synthetic render."""

    def setUp(self):
        self.images = g.collect_images(RENDER)

    def test_all_images_found(self):
        self.assertEqual(set(self.images), {
            f"{GAR}/keycloak-zeta:1.3.2", f"{GAR}/provisioning-processor:1.3.2",
            f"{GAR}/keychain-generator:2.0.4", f"{GAR}/postgres:17.11-standard-trixie"})

    def test_init_container_is_an_image_too(self):
        self.assertEqual(self.images[f"{GAR}/keychain-generator:2.0.4"], {"Deployment/authserver"})

    def test_workloads_are_collected_per_image(self):
        self.assertEqual(self.images[f"{GAR}/provisioning-processor:1.3.2"], {"Deployment/authserver", "CronJob/opa-rollout"})

    def test_cnpg_cluster_image(self):
        self.assertEqual(self.images[f"{GAR}/postgres:17.11-standard-trixie"], {"Cluster/keycloak-db"})

    def test_documents_without_images_are_ignored(self):
        # a non-list "containers" value must be skipped, not crash the walk
        self.assertNotIn("not-a-list", "".join(self.images))

    def test_null_and_blank_lines(self):
        # yq emits "null" for templates that render nothing
        self.assertEqual(g.collect_images("\nnull\n\n"), {})


class MergeRenders(unittest.TestCase):
    """optional = only in the 'everything enabled' render; result = union of both renders."""

    def test_optional_and_union(self):
        minimal = {"a:1": {"Deployment/a"}, "pg-default:1": {"Cluster/db"}}
        everything = {"a:1": {"Deployment/a", "CronJob/a"}, "b:2": {"Deployment/b"}}
        merged = g.merge_renders(minimal, everything)
        self.assertEqual(merged["a:1"], (False, {"Deployment/a", "CronJob/a"}))
        self.assertEqual(merged["b:2"], (True, {"Deployment/b"}))
        # only in the default render (replaced when an option is enabled) must survive
        self.assertEqual(merged["pg-default:1"], (False, {"Cluster/db"}))


class ImageComponent(unittest.TestCase):
    """CycloneDX container component: purl, hashes only with a digest, zeta:* properties."""

    def test_tagged_with_digest(self):
        c = g.image_component(f"{GAR}/ngx_pep:1.3.3", False, DIGEST, {"Deployment/pep", "DaemonSet/x"})
        self.assertEqual(c["name"], "ngx_pep")
        self.assertEqual(c["version"], "1.3.3")
        self.assertEqual(c["purl"], f"pkg:oci/ngx_pep@{DIGEST}?repository_url={GAR}/ngx_pep&tag=1.3.3")
        self.assertEqual(c["hashes"], [{"alg": "SHA-256", "content": "ab" * 32}])
        self.assertEqual([p["value"] for p in c["properties"] if p["name"] == "zeta:k8s-workload"],
                         ["DaemonSet/x", "Deployment/pep"])  # sorted, one property per workload
        self.assertIn({"name": "zeta:optional", "value": "false"}, c["properties"])
        self.assertIn({"name": "zeta:kind", "value": "oci-image"}, c["properties"])
        self.assertNotIn("zeta:source", [p["name"] for p in c["properties"]])  # registry is in the purl
        self.assertEqual(c["bom-ref"], "img:ngx_pep:1.3.3")  # short, readable

    def test_without_digest_has_no_hashes(self):
        c = g.image_component("alpine:3.17", True, "")
        self.assertNotIn("hashes", c)
        self.assertEqual(c["purl"], "pkg:oci/alpine?repository_url=alpine&tag=3.17")
        self.assertIn({"name": "zeta:optional", "value": "true"}, c["properties"])
        self.assertIn({"name": "zeta:kind", "value": "oci-image"}, c["properties"])

    def test_digest_pinned_uses_digest_as_version(self):
        c = g.image_component(f"python@{DIGEST}", False, DIGEST)
        self.assertEqual(c["version"], DIGEST)
        self.assertEqual(c["purl"], f"pkg:oci/python@{DIGEST}?repository_url=python")


class NamesAndRefs(unittest.TestCase):
    """disambiguate_names() / unique_bom_refs(): readable names and bom-refs that stay unique."""

    def test_variants_named_after_their_workload(self):
        # one repository, two builds (-rs/-fdv), each used by exactly one Deployment
        comps = [g.image_component(f"{GAR}/notification-service:1.3.2-rs", True, "", {"Deployment/notification-service-rs"}),
                 g.image_component(f"{GAR}/notification-service:1.3.2-fdv", True, "", {"Deployment/notification-service-fdv"})]
        g.disambiguate_names(comps)
        self.assertEqual([c["name"] for c in comps], ["notification-service-rs", "notification-service-fdv"])
        self.assertEqual(comps[0]["bom-ref"], "img:notification-service-rs:1.3.2-rs")

    def test_same_artifact_from_two_registries_keeps_name(self):
        # umbrella: opa from docker.io and from GAR, same tag, same workloads -> not variants
        comps = [g.image_component("docker.io/openpolicyagent/opa:1.19.1-static", False, "", {"Deployment/opa", "Deployment/opa-simulation"}),
                 g.image_component(f"{GAR}/opa:1.19.1-static", True, "", {"Deployment/opa", "Deployment/opa-simulation"})]
        g.disambiguate_names(comps)
        self.assertEqual({c["name"] for c in comps}, {"opa"})

    def test_colliding_bom_refs_fall_back_to_full_reference(self):
        comps = [g.image_component("docker.io/openpolicyagent/opa:1.19.1-static", False, ""),
                 g.image_component(f"{GAR}/opa:1.19.1-static", True, ""),
                 g.image_component("alpine:3.17", True, "")]
        g.unique_bom_refs(comps)
        self.assertEqual([c["bom-ref"] for c in comps],
                         ["img:docker.io/openpolicyagent/opa:1.19.1-static", f"img:{GAR}/opa:1.19.1-static", "img:alpine:3.17"])


class SubchartComponent(unittest.TestCase):
    """CycloneDX application component for a Chart.yaml dependency."""

    def test_full(self):
        c = g.subchart_component({"name": "cluster", "version": "0.8.1", "alias": "keycloak-db",
                                  "condition": "keycloak-db.enabled", "repository": "oci://ghcr.io/cloudnative-pg/charts"})
        self.assertEqual(c["bom-ref"], "chart:cluster:0.8.1")
        self.assertEqual(c["group"], "ghcr.io/cloudnative-pg/charts")  # a Helm chart, not a container
        self.assertNotIn("description", c)  # none given
        self.assertIn({"name": "zeta:kind", "value": "helm-chart"}, c["properties"])
        self.assertIn({"name": "zeta:optional", "value": "true"}, c["properties"])
        self.assertIn({"name": "zeta:alias", "value": "keycloak-db"}, c["properties"])
        self.assertEqual(c["externalReferences"][0]["url"], "oci://ghcr.io/cloudnative-pg/charts")

    def test_minimal_local_subchart(self):
        c = g.subchart_component({"name": "testdriver", "version": "0.0.1"})
        self.assertEqual(c["properties"], [{"name": "zeta:kind", "value": "helm-chart"}, {"name": "zeta:optional", "value": "false"}])
        self.assertNotIn("externalReferences", c)
        self.assertNotIn("group", c)
        self.assertNotIn("alias", json.dumps(c))

    def test_bundled_subchart_has_no_distribution_reference(self):
        # "repository: file://charts/x" means the sub-chart only exists inside this chart's tarball
        c = g.subchart_component({"name": "push-gateway", "version": "0.0.1", "repository": "file://charts/push-gateway"})
        self.assertNotIn("externalReferences", c)
        self.assertNotIn("group", c)

    def test_description_from_subchart(self):
        c = g.subchart_component({"name": "cluster", "version": "0.8.1"}, "Deploys and manages a CloudNativePG cluster.")
        self.assertEqual(c["description"], "Deploys and manages a CloudNativePG cluster.")


class BuildBom(unittest.TestCase):
    """Document skeleton: header, serial/timestamp format, root component, dependsOn lists exactly
    the components."""

    def test_structure(self):
        comps = [g.image_component("alpine:3.17", False, ""), g.subchart_component({"name": "x", "version": "1"})]
        bom = g.build_bom({"name": "zeta-guard", "version": "1.3.4", "description": "ZETA Guard"}, comps)
        self.assertEqual((bom["bomFormat"], bom["specVersion"], bom["version"]), ("CycloneDX", "1.6", 1))
        self.assertRegex(bom["serialNumber"], r"^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        self.assertRegex(bom["metadata"]["timestamp"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        self.assertEqual(bom["metadata"]["component"]["bom-ref"], "chart:zeta-guard:1.3.4")
        # the root links to the documentation of the zeta:* properties
        self.assertEqual(bom["metadata"]["component"]["externalReferences"][0]["type"], "documentation")
        self.assertEqual(bom["metadata"]["component"]["externalReferences"][0]["url"], g.DOCS_URL)
        refs = {c["bom-ref"] for c in bom["components"]}
        self.assertEqual(set(bom["dependencies"][0]["dependsOn"]), refs)
        self.assertEqual(bom["dependencies"][0]["ref"], "chart:zeta-guard:1.3.4")

    def test_nested_subchart_dependencies(self):
        # images listed in a sub-chart's SBOM hang below that sub-chart, the rest below the root
        comps = [g.image_component("kc:1", False, ""), g.image_component("test:1", False, ""),
                 g.subchart_component({"name": "zeta-guard", "version": "1.3.4"}),
                 g.subchart_component({"name": "hsmsim", "version": "0.0.1"})]
        bom = g.build_bom({"name": "zeta-testenv", "version": "1.3.4"}, comps, {"zeta-guard": {"kc:1", "other:9"}})
        deps = {d["ref"]: d["dependsOn"] for d in bom["dependencies"]}
        self.assertEqual(deps["chart:zeta-guard:1.3.4"], ["img:kc:1"])  # unknown "other:9" ignored
        self.assertEqual(deps["chart:zeta-testenv:1.3.4"], ["img:test:1", "chart:zeta-guard:1.3.4", "chart:hsmsim:0.0.1"])

    def test_nested_unknown_subchart_fails(self):
        comps = [g.subchart_component({"name": "hsmsim", "version": "0.0.1"})]
        with self.assertRaises(ValueError):
            g.build_bom({"name": "n", "version": "1"}, comps, {"zeta-guard": set()})

    def test_json_serialisable(self):
        # a numeric chart version (YAML "version: 1") must become a string
        bom = g.build_bom({"name": "n", "version": 1}, [])
        json.dumps(bom)
        self.assertEqual(bom["metadata"]["component"]["version"], "1")


if __name__ == "__main__":
    unittest.main()
