#!/usr/bin/env python3
"""CycloneDX 1.6 SBOM (JSON) for a Helm chart: which container images does the chart deploy?

Steps:
1. `helm template` twice: with the chart's default values, and additionally with an
   "everything enabled" values file (--all-values) that switches on every optional component.
2. Collect every image from the rendered manifests: containers and init containers of all pod
   specs, plus `spec.imageName` of CloudNativePG clusters. Remember the workloads (Kind/name).
3. Merge both renders: an image only present in the second one is optional. The result is the
   union, because enabling an option can also *replace* a component (keycloak-db upstream chart).
4. Optionally (--resolve-digests) look up every image's digest via `skopeo` in the registry the
   reference points to (gematik PROD for zeta images, Docker Hub / ghcr.io for third-party ones).
   Images that registry does not have yet are reported (and written to --missing-out); their digest
   is then taken from the source repository named in --digest-fallback (same digest, e.g. the
   GitLab registry the image was built in), so every entry carries a digest.
5. Write the document: the chart as root component, one `container` component per image with
   purl (pkg:oci), hashes and the properties zeta:image / zeta:kind oci-image / zeta:optional /
   zeta:k8s-workload (one per workload), one `application` component per Chart.yaml dependency
   (zeta:kind helm-chart), and `dependencies` chart -> all of them.
   Images sharing a name but differing in content (e.g. notification-service -rs/-fdv) are named
   after the workload using them; bom-refs are short (img:<name>:<tag>) unless that collides.
   With --subchart-sbom NAME=FILE (the SBOM of a sub-chart generated before) the images listed
   there are attributed to that sub-chart instead: chart -> sub-chart -> its images, so a reader
   sees which images belong to e.g. zeta-guard without comparing two files.

Usage (normally via `make sbom`):
    generate_sbom.py -c <chart-dir> -o <out.cdx.json> [-f <values>]... [--set k=v]...
                     [--all-values <file>] [--resolve-digests] [--missing-out <file>]
                     [--digest-fallback <yaml: referenced repo -> source repo>]
                     [--subchart-sbom <name>=<sbom.cdx.json>]...

Requires helm and yq (v4); skopeo only with --resolve-digests. Standard library only.
Unit tests: `make sbom-test`.
"""
import argparse
import datetime
import os
import hashlib
import json
import re
import subprocess
import sys
import time
import uuid

# [registry[:port]/][path/]name[:tag][@sha256:digest] — repo is matched lazily and a tag may not
# contain "/", so a registry port ("reg:443/img") stays part of the repo.
IMAGE_REF = re.compile(r"^(?P<repo>.+?)(?::(?P<tag>[^/:@]+))?(?:@(?P<digest>sha256:[0-9a-f]+))?$")

KIND = "zeta:kind"  # oci-image or helm-chart; `type` alone is too coarse for charts (application)
WORKLOAD = "zeta:k8s-workload"
# where the zeta:* properties and the document structure are described
DOCS_URL = "https://github.com/gematik/zeta/blob/main/docs/user-manual/Referenzen/SBOM.md"


def run(*cmd, stdin=None):
    """Run a command and return its stdout. On failure the command's own error message is shown
    (e.g. helm's "value X is required"), not just a traceback."""
    result = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"{cmd[0]} failed ({' '.join(cmd[:3])} …):\n{result.stderr.strip()}")
    return result.stdout


def yq_json(*args, stdin=None):
    """yq with JSON output; the caller parses it."""
    return run("yq", "-o=json", *args, stdin=stdin)


def parse_image(image):
    """'reg/path/name:tag@sha256:…' -> (repo, name, tag or None, digest or '')."""
    m = IMAGE_REF.match(image)
    repo = m.group("repo")
    return repo, repo.rsplit("/", 1)[-1], m.group("tag"), m.group("digest") or ""


def dict_nodes(node):
    """Every dict inside a JSON document, depth first. Pod specs sit at different depths
    (Deployment vs. CronJob), so the whole document is walked."""
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from dict_nodes(v)
    elif isinstance(node, list):
        for v in node:
            yield from dict_nodes(v)


def node_images(node):
    """Images referenced directly by one dict node: its containers / initContainers, and
    spec.imageName of a CloudNativePG `Cluster` resource."""
    for key in ("containers", "initContainers"):
        containers = node.get(key)
        for c in containers if isinstance(containers, list) else []:
            if isinstance(c, dict) and c.get("image"):
                yield c["image"]
    if node.get("kind") == "Cluster" and node.get("spec", {}).get("imageName"):
        yield node["spec"]["imageName"]


def collect_images(json_docs):
    """{image: {"Kind/name", ...}} from rendered manifests, one JSON document per line."""
    images = {}
    for line in json_docs.splitlines():
        doc = json.loads(line) if line.strip() else None
        if not isinstance(doc, dict):  # blank line, or "null" for an empty YAML document
            continue
        workload = f"{doc.get('kind', '?')}/{doc.get('metadata', {}).get('name', '?')}"
        for node in dict_nodes(doc):
            for image in node_images(node):
                images.setdefault(image, set()).add(workload)
    return images


def rendered_images(chart, helm_args):
    """Render the chart and collect its images; yq turns the YAML stream into one JSON doc per line.
    The release name is "sbom", so sub-charts that prefix resource names with it appear as e.g.
    "DaemonSet/sbom-nginx-ingress-controller"."""
    manifests = run("helm", "template", "sbom", chart, *helm_args)
    return collect_images(yq_json("-I=0", "select(. != null)", stdin=manifests))


def merge_renders(minimal, everything):
    """Union of both renders -> {image: (optional, workloads)}; optional = not in the default render.
    Union, not just the second render: enabling an option can replace a component (keycloak-db
    upstream chart vs. hand-rolled Cluster), and the default image must stay in the SBOM."""
    merged = {}
    for image in set(minimal) | set(everything):
        workloads = minimal.get(image, set()) | everything.get(image, set())
        merged[image] = (image not in minimal, workloads)
    return merged


def lookup_ref(image):
    """skopeo rejects 'repo:tag@digest', so a pinned image is looked up as 'repo@digest'."""
    repo, _, _, digest = parse_image(image)
    return f"{repo}@{digest}" if digest else image


def fallback_refs(image, fallback):
    """Alternative references to try when the referenced registry does not have the image:
    the same tag/digest under the source repository mapped in `fallback` ({repo: source repo})."""
    repo, _, tag, digest = parse_image(image)
    source = fallback.get(repo)
    if not source:
        return []
    if digest:
        return [f"{source}@{digest}"]
    return [f"{source}:{tag}" if tag else source]


def manifest_digest(ref, attempts=2):
    """Digest of what `ref` points to, or '' if the registry does not have it (or denies access).

    `skopeo inspect --raw` returns the manifest (or index for multi-arch images) byte for byte;
    its SHA-256 is the digest a pull by tag resolves to (the cosign CLI, which the CI already has,
    offers no such lookup). One retry absorbs transient registry errors (rate limits, token
    hiccups), so an image is not reported missing by accident."""
    for attempt in range(attempts):
        try:
            raw = subprocess.run(["skopeo", "inspect", "--raw", f"docker://{ref}"],
                                 check=True, capture_output=True).stdout
            return "sha256:" + hashlib.sha256(raw).hexdigest()
        except subprocess.CalledProcessError as e:
            if b"manifest unknown" in e.stderr or b"not found" in e.stderr.lower() or attempt == attempts - 1:
                return ""
            time.sleep(2)
    return ""


def digest_of(image, resolve, fallback=None):
    """(digest or '', found, source).

    found: does the *referenced* registry have the image (True/False; None without resolve).
    source: where the digest was confirmed — "referenced", "fallback" (resolved from the source
    repository mapped in `fallback`, so the SBOM still carries a digest for images not promoted
    yet), or "" (nowhere; a pinned digest is then kept unverified)."""
    pinned = parse_image(image)[3]
    if not resolve:
        return pinned, None, ""
    digest = manifest_digest(lookup_ref(image))
    if digest:
        return pinned or digest, True, "referenced"
    for ref in fallback_refs(image, fallback or {}):
        digest = manifest_digest(ref)
        if digest:
            return pinned or digest, False, "fallback"
    return pinned, False, ""


def image_component(image, optional, digest, workloads=()):
    """CycloneDX `container` component: purl pkg:oci/<name>[@digest]?repository_url=…[&tag=…],
    hashes only when the digest is known, one zeta:k8s-workload property per workload.
    zeta:image (the reference as rendered) is always the first property; other code relies on it."""
    repo, name, tag, _ = parse_image(image)
    purl = f"pkg:oci/{name}" + (f"@{digest}" if digest else "") + f"?repository_url={repo}" + (f"&tag={tag}" if tag else "")
    component = {
        "type": "container", "name": name, "version": tag or digest, "bom-ref": f"img:{name}:{tag or digest}", "purl": purl,
        "properties": [{"name": "zeta:image", "value": image},
                       {"name": KIND, "value": "oci-image"},
                       {"name": "zeta:optional", "value": str(optional).lower()}]
                      + [{"name": WORKLOAD, "value": w} for w in sorted(workloads)],
    }
    if digest:
        component["hashes"] = [{"alg": "SHA-256", "content": digest.split(":", 1)[1]}]
    return component


def image_of(component):
    return component["properties"][0]["value"]


def workload_names(group):
    """One name per component, taken from its workload, if every component of the group is used
    by exactly one workload and no two share it; otherwise None (the names stay as they are)."""
    workloads = [[p["value"] for p in c["properties"] if p["name"] == WORKLOAD] for c in group]
    if all(len(w) == 1 for w in workloads) and len({w[0] for w in workloads}) == len(group):
        return [w[0].split("/", 1)[1] for w in workloads]
    return None


def disambiguate_names(components):
    """Images that share a name but are different artifacts (e.g. notification-service:1.3.2-rs
    and -fdv, two builds from one repository) get the name of the workload using them, provided
    each is used by exactly one workload. Same artifact under several references keeps its name."""
    by_name = {}
    for c in components:
        if c["type"] == "container":
            by_name.setdefault(c["name"], []).append(c)
    for group in by_name.values():
        if len(group) < 2 or len({c["version"] for c in group}) < 2:
            continue
        for c, name in zip(group, workload_names(group) or []):
            c["name"] = name
            c["bom-ref"] = f"img:{name}:{c['version']}"
    return components


def unique_bom_refs(components):
    """bom-refs are short (img:<name>:<tag>) for readability; a collision inside one document
    (e.g. the same image name from two registries) falls back to the full reference."""
    seen = {}
    for c in components:
        seen.setdefault(c["bom-ref"], []).append(c)
    for refs in seen.values():
        if len(refs) > 1:
            for c in refs:
                c["bom-ref"] = f"img:{image_of(c)}"
    return components


def subchart_description(chart, dep):
    """Description from the sub-chart's own Chart.yaml: vendored tarball (remote dependency) or
    directory (local sub-chart); '' when neither is present."""
    tgz = f"{chart}/charts/{dep['name']}-{dep['version']}.tgz"
    local = f"{chart}/charts/{dep['name']}/Chart.yaml"
    try:
        if os.path.exists(tgz):
            return run("yq", ".description // \"\"", stdin=run("helm", "show", "chart", tgz)).strip()
        if os.path.exists(local):
            return run("yq", ".description // \"\"", local).strip()
    except subprocess.CalledProcessError:
        pass
    return ""


def subchart_component(dep, description=""):
    """CycloneDX `application` component for a Chart.yaml dependency (a Helm chart, not an image);
    optional = has a condition. `group` (chart repository) and `description` (from the sub-chart's
    Chart.yaml) say what e.g. the CloudNativePG chart "cluster" is."""
    component = {
        "type": "application", "name": dep["name"], "version": str(dep["version"]),
        "bom-ref": f"chart:{dep['name']}:{dep['version']}",
        "properties": [{"name": KIND, "value": "helm-chart"},
                       {"name": "zeta:optional", "value": str("condition" in dep).lower()}],
    }
    if description:
        component["description"] = description
    if dep.get("alias"):
        component["properties"].append({"name": "zeta:alias", "value": dep["alias"]})
    repository = dep.get("repository", "")
    if repository and not repository.startswith("file://"):  # file:// = bundled in this chart, no distribution point
        component["group"] = re.sub(r"^[a-z]+://", "", repository)
        component["externalReferences"] = [{"type": "distribution", "url": repository}]
    return component


def dependencies(root_ref, components, nested=None):
    """Dependency tree. Flat by default: root -> every component. With `nested`
    ({sub-chart name: {image references}}) the listed images hang below their sub-chart component
    instead: root -> sub-chart -> images; the rest stays directly below the root."""
    nested = nested or {}
    refs_by_image = {image_of(c): c["bom-ref"] for c in components if c["type"] == "container"}
    subchart_ref = {c["name"]: c["bom-ref"] for c in components if c["type"] == "application"}
    attributed, tree = set(), []
    for sub, images in nested.items():
        if sub not in subchart_ref:
            raise ValueError(f"--subchart-sbom: '{sub}' is not a dependency of this chart")
        mine = sorted(refs_by_image[i] for i in images if i in refs_by_image)
        attributed.update(mine)
        tree.append({"ref": subchart_ref[sub], "dependsOn": mine})
    root = [c["bom-ref"] for c in components if c["bom-ref"] not in attributed]
    return [{"ref": root_ref, "dependsOn": root}] + tree


def build_bom(chart_meta, components, nested=None):
    """Document skeleton: the chart is the root component, dependencies per dependencies().
    serialNumber is a fresh UUID per document (compare SBOMs by content, not by serial)."""
    name, version = chart_meta["name"], str(chart_meta["version"])
    root_ref = f"chart:{name}:{version}"
    return {
        "bomFormat": "CycloneDX", "specVersion": "1.6", "serialNumber": f"urn:uuid:{uuid.uuid4()}", "version": 1,
        "metadata": {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "tools": {"components": [{"type": "application", "name": "generate_sbom.py"}]},
            "component": {"type": "application", "name": name, "version": version,
                          "description": chart_meta.get("description", ""), "bom-ref": root_ref,
                          "properties": [{"name": KIND, "value": "helm-chart"}],
                          "externalReferences": [{"type": "documentation", "url": DOCS_URL,
                                                  "comment": "structure of this SBOM and meaning of the zeta:* properties"}]},
        },
        "components": components,
        "dependencies": dependencies(root_ref, components, nested),
    }


def nested_images(specs):
    """{sub-chart: {image, ...}} from --subchart-sbom NAME=FILE arguments."""
    nested = {}
    for spec in specs:
        sub, path = spec.split("=", 1)
        with open(path) as fh:
            nested[sub] = {image_of(c) for c in json.load(fh)["components"] if c["type"] == "container"}
    return nested


def report_missing(digests, chart_name, missing_out):
    """stderr list of images the registry their reference points to does not have, also appended
    to `missing_out` (chart name + image per line): the "is everything in the registry?" check."""
    note = {"fallback": "  (digest resolved via fallback)", "": "  (no digest / pinned digest unverified)"}
    missing = [img for img, (_, found, _) in digests.items() if not found]
    if not missing:
        return
    print("images not found in the registry their reference points to (for zeta images: gematik PROD):\n  "
          + "\n  ".join(img + note[digests[img][2]] for img in missing), file=sys.stderr)
    if missing_out:
        with open(missing_out, "a") as fh:
            fh.writelines(f"{chart_name} {img}\n" for img in missing)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-c", "--chart", required=True, help="chart directory")
    p.add_argument("-o", "--out", help="output file (default: <chart>/sbom.cdx.json)")
    p.add_argument("-f", "--values", action="append", default=[], help="values file for both renders")
    p.add_argument("--set", action="append", default=[], help="--set for both renders (e.g. required secrets)")
    p.add_argument("--all-values", help="values file enabling every optional component (second render)")
    p.add_argument("--resolve-digests", action="store_true", help="look up image digests via skopeo")
    p.add_argument("--missing-out", help="append images the registry does not have to this file")
    p.add_argument("--digest-fallback", help="YAML {referenced repo: source repo} to resolve digests of images not yet in their registry")
    p.add_argument("--subchart-sbom", action="append", default=[], metavar="NAME=FILE",
                   help="attribute the images listed in a sub-chart's SBOM to that sub-chart (repeatable)")
    a = p.parse_args()

    chart_meta = json.loads(yq_json(".", f"{a.chart}/Chart.yaml"))
    out = a.out or f"{a.chart}/sbom.cdx.json"

    # steps 1-3: render twice, collect, merge
    helm_args = [x for f in a.values for x in ("-f", f)] + [x for s in a.set for x in ("--set", s)]
    minimal = rendered_images(a.chart, helm_args)
    everything = rendered_images(a.chart, helm_args + (["-f", a.all_values] if a.all_values else []))
    images = merge_renders(minimal, everything)
    if not images:
        sys.exit("render produced no images")

    # steps 4-5: digests, components, document
    fallback = json.loads(yq_json(".", a.digest_fallback)) if a.digest_fallback else {}
    digests = {img: digest_of(img, a.resolve_digests, fallback) for img in sorted(images)}
    components = [image_component(img, images[img][0], digests[img][0], images[img][1]) for img in sorted(images)]
    components = unique_bom_refs(disambiguate_names(components))
    components += [subchart_component(d, subchart_description(a.chart, d)) for d in chart_meta.get("dependencies", [])]

    with open(out, "w") as fh:
        json.dump(build_bom(chart_meta, components, nested_images(a.subchart_sbom)), fh, indent=2)
        fh.write("\n")

    # summary on stderr
    print(f"wrote {out}: {len(images)} images, {len(components) - len(images)} sub-charts", file=sys.stderr)
    if a.resolve_digests:
        report_missing(digests, chart_meta["name"], a.missing_out)
    else:
        print("digests not resolved (run with --resolve-digests)", file=sys.stderr)


if __name__ == "__main__":
    main()
