# Show the help target when `make` is run without arguments.
.DEFAULT_GOAL := help

# VALUES_DIR: honor an explicit override (env or CLI); else private/ if it exists;
# otherwise fall back to local-test/. Uses ifndef (not ?=) because the default is computed.
ifndef VALUES_DIR
ifeq ($(wildcard private/),)
  VALUES_DIR := local-test/
else
  VALUES_DIR := private/
endif
endif
override VALUES_DIR := $(VALUES_DIR:/=)/

# Optional single-parameter env selection: `make deploy stage=<env>`
# If not provided, default to 'local'.
STAGE := $(strip $(if $(stage),$(stage),local))

# k3s -> local + k3s
ifeq ($(STAGE),k3s)
  HELM_EXTRA_VALUES_PARAMS := --values $(VALUES_DIR)values.k3s.yaml
  STAGE := local
  TF_VARS := $(VALUES_DIR)k3s.tfvars
else
  TF_VARS := $(VALUES_DIR)$(STAGE).tfvars
endif

# Release name is always derived from STAGE; ignore overrides silently
override RELEASE := zeta-testenv-$(STAGE)

# Namespace: if provided as 'namespace', use it; else default to zeta-<stage>
ifdef namespace
  NAMESPACE := $(namespace)
else
  NAMESPACE := zeta-$(STAGE)
endif

# Values file: if provided as 'values', use it; else select values.<stage>.yaml in VALUES_DIR
ifdef values
  VALUES := $(values)
else
  VALUES := $(VALUES_DIR)values.$(STAGE).yaml
endif
SUBCHARTS := $(wildcard charts/*/Chart.yaml)
# Database bootstrap mode for local convenience targets
DB_MODE ?= cloudnative
# Terraform config variables
TF_PATH := terraform/authserver
TF_VAR_config_path ?= "~/.kube/config"
TF_VAR_use_kubernetes ?= true
export TF_VAR_keycloak_password
# Plan file name shared by `config-plan` (writes it) and `config-show-plan` (renders it).
# When set, `make config-plan PLAN_OUT=<file>` saves the plan so it can be reviewed later
# via `make config-show-plan PLAN_OUT=<file>`. Empty (default) = no plan file is written.
PLAN_OUT ?=

# Achelos uses hostAliases for direct OCSP mock routing when DNS redirect is
# enabled. hostAliases require a literal IP, so keep a reserved fallback for the
# first-ever deploy when no zeta-cert-validation-mock Service exists yet.
ACHELOS_ZETA_CERT_VALIDATION_MOCK_FALLBACK_CLUSTER_IP ?= 10.0.0.240

# Enforce SMB keystore vars only for targets that actually pass them to Helm
ifneq ($(filter deploy deploy-debug template template--debug render dry-run,$(MAKECMDGOALS)),)

ifeq ($(strip $(SMB_KEYSTORE_PW_FILE)),)
$(error SMB_KEYSTORE_PW_FILE must not be empty)
endif

ifeq ($(strip $(SMB_KEYSTORE_FILE_B64)),)
$(error SMB_KEYSTORE_FILE_B64 must not be empty)
endif

ifneq ($(strip $(OCSP_SMB_KEYSTORE_PW_FILE)),)
override HELM_EXTRA_VALUES_PARAMS += --set-file "zeta-cert-validation-mock.signing.smb.keyStorePassword=${OCSP_SMB_KEYSTORE_PW_FILE}"
endif

ifneq ($(strip $(OCSP_SMB_KEYSTORE_FILE_B64)),)
override HELM_EXTRA_VALUES_PARAMS += --set-file "zeta-cert-validation-mock.signing.smb.keyStore=${OCSP_SMB_KEYSTORE_FILE_B64}"
endif

# achelos + achelos-2 share the same admin password, genesisHash and pepper.
ifneq ($(filter $(STAGE),achelos achelos-2),)
override HELM_EXTRA_VALUES_PARAMS += --set-string "zeta-guard.authserver.admin.password=$(KEYCLOAK_ACHELOS_PW)"
override HELM_EXTRA_VALUES_PARAMS += --set-string "zeta-guard.authserver.genesisHash=4841c2142fef441daa6ee6c57db65c011935964b14e94a6c8f5ec0447b83526c"
override HELM_EXTRA_VALUES_PARAMS += --set-string "zeta-guard.authserver.smcbHashingPepper=085c1245-dc0d-4d39-95b4-97496bec6182"
endif

# add override to allow additional params, e.g. `make <cmd> HELM_EXTRA_VALUES_PARAMS=--debug`
override HELM_EXTRA_VALUES_PARAMS += --set-file "smcb_keystore.password=${SMB_KEYSTORE_PW_FILE}" --set-file "smcb_keystore.keystore=${SMB_KEYSTORE_FILE_B64}"

# Preserve immutable Service IPs when rendering against an existing cluster.
# This covers `helm template | kubectl apply --dry-run=server`, where Helm's
# lookup function does not have the live object state available.
ifeq ($(STAGE),achelos)
ZETA_CERT_VALIDATION_MOCK_CLUSTER_IP := $(or $(shell kubectl --request-timeout=3s -n $(NAMESPACE) get service zeta-cert-validation-mock -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true),$(ACHELOS_ZETA_CERT_VALIDATION_MOCK_FALLBACK_CLUSTER_IP))
ifneq ($(strip $(filter-out None,$(ZETA_CERT_VALIDATION_MOCK_CLUSTER_IP))),)
override HELM_EXTRA_VALUES_PARAMS += --set-string "global.dns.tigerStaticClusterIP=$(ZETA_CERT_VALIDATION_MOCK_CLUSTER_IP)"
override HELM_EXTRA_VALUES_PARAMS += --set-string "zeta-cert-validation-mock.service.clusterIP=$(ZETA_CERT_VALIDATION_MOCK_CLUSTER_IP)"
endif
else
TIGER_PROXY_CLUSTER_IP := $(shell kubectl --request-timeout=3s -n $(NAMESPACE) get service tiger-proxy -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
ifneq ($(strip $(filter-out None,$(TIGER_PROXY_CLUSTER_IP))),)
override HELM_EXTRA_VALUES_PARAMS += --set-string "global.dns.tigerStaticClusterIP=$(TIGER_PROXY_CLUSTER_IP)"
endif
endif

endif

# For the local-guard stage, inject the detected HOST_IP into the NetworkPolicy so that the PEP proxy
# can reach the ingress (zeta-kind.local → HOST_IP via CoreDNS) for JWK fetches without hardcoding
# the IP in values.local-guard.yaml. HOST_IP is auto-detected (same value used to patch CoreDNS).
ifeq ($(STAGE),local-guard)
  override HELM_EXTRA_VALUES_PARAMS += --set "zeta-guard.networkPolicy.egress.providerInternal.resourceServers.ipBlocks[0]=$(HOST_IP)/32"
endif

.PHONY: \
  help deps deps-update strip-remote-schemas lint template-demo yamllint \
  install-cert-manager install-metrics-server install-cnpg-operator uninstall-cnpg-operator reset-cnpg-operator \
  template template--debug render dry-run \
  deploy deploy-debug history rollback \
  generate-main-and-backend config-init config config-plan config-show-plan config-import \
  status notes versions versions-debug release-versions uninstall clean \
  dry-run-security-restricted security-restricted security-disable show-label \
  generate-asl-identity-secret \
  renew-opa-token \
  kind-up kind-down k3s k3s-down myip create-secrets \
  proxy-up proxy-down proxy-verify \
  trivy

FORCE:

help: ## Show available targets, usage, and effective vars
	@echo "Usage: make <target> [stage=<env>] [namespace=<ns>] [values=<path>]"
	@echo "       stage defaults to 'local' when omitted"
	@echo
	@awk 'BEGIN {FS=":.*## "}; /^[a-zA-Z0-9_.-]+:.*## /{printf "  %-28s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
ifneq ($(wildcard private/),)
	@echo
	@echo "Targets requiring private/:"
	@awk 'BEGIN {FS=":.*##! "}; /^[a-zA-Z0-9_.-]+:.*##! /{printf "  %-28s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
endif
	@echo
	@echo "Key variables (env var or make arg; full list: docs/reference/Makefile_reference.md):"
	@printf "  %-28s %s\n" "SMB_KEYSTORE_PW_FILE" "SMCB keystore password file (required for deploy/template/render/dry-run)"
	@printf "  %-28s %s\n" "SMB_KEYSTORE_FILE_B64" "SMCB keystore base64 file (required for deploy/template/render/dry-run)"
	@printf "  %-28s %s\n" "TF_VAR_keycloak_password" "Keycloak admin password (config / config-plan)"
	@echo
	@printf "Vars (effective):\n RELEASE=%s\n NAMESPACE=%s\n VALUES=%s\n VALUES_DIR=%s\n STAGE=%s\n" "$(RELEASE)" "$(NAMESPACE)" "$(VALUES)" "$(VALUES_DIR)" "$(STAGE)"


# The umbrella's local subcharts are declared WITHOUT a repository field:
# helm resolves them directly from the unpacked source dirs in charts/ —
# no vendoring, no Chart.lock, no stale-tgz race (there is no second copy),
# and edits are picked up live. Only the two subcharts with REMOTE deps
# (zeta-guard: nginx-ingress + opentelemetry-collector,
#  test-monitoring-service: opentelemetry-demo) need `helm dependency build`.
# All remote deps are oci:// — served from helm's content cache
# (HELM_CONTENT_CACHE) after the first pull, so this is fast, offline-capable,
# and needs no `helm repo add`. `build` fails with "out of sync" after editing
# a dependency in Chart.yaml — run `make deps-update` then to re-resolve.
# helm chatter -> stderr: template/render pipe manifests from stdout.
# Also purges STALE packaged local subcharts: the umbrella references its
# subcharts as unpacked dirs (no repository field), so helm never creates
# charts/*.tgz for them — any that exist are leftovers from the old file://
# `make deps`, and helm nondeterministically loads the stale tgz over the live
# source dir ("my edit didn't take"). Deletes only a top-level tgz SHADOWED by a
# same-named source dir; a hypothetical future umbrella-level *remote* dep
# (vendored legitimately as charts/<name>.tgz, no source dir) is left alone.
# Nested remote-dep tgz (charts/*/charts/*.tgz) aren't matched by the glob and
# are pruned by `helm dependency build` itself ("Deleting outdated charts").
deps: ## Vendor the subcharts' remote deps as pinned in their Chart.lock (cache-served)
	@for tgz in charts/*.tgz; do \
		[ -e "$$tgz" ] || continue; \
		name=$$(tar -tzf "$$tgz" 2>/dev/null | head -1 | cut -d/ -f1); \
		if [ -n "$$name" ] && [ -d "charts/$$name" ]; then \
			printf 'deps: removing stale packaged subchart %s (charts/%s/ shadows it)\n' "$$tgz" "$$name" 1>&2; \
			rm -f "$$tgz"; \
		fi; \
	done
	@helm dependency build --skip-refresh charts/test-monitoring-service 1>&2
	@helm dependency build --skip-refresh charts/zeta-guard 1>&2
	@$(MAKE) --no-print-directory strip-remote-schemas 1>&2

deps-update: ## Re-resolve the subcharts' remote dep versions and rewrite their Chart.lock
	helm dependency update charts/test-monitoring-service
	helm dependency update charts/zeta-guard
	@$(MAKE) --no-print-directory strip-remote-schemas

# nginx-ingress' values.schema.json $refs raw.githubusercontent.com, which helm
# re-fetches uncached on EVERY lint/template/upgrade — a rate-limited egress IP
# then kills the deploy with `429 (Too Many Requests)` before the first manifest
# is rendered. Strip the schema from the vendored tarball (only our own charts'
# schemas matter, and they stay enforced) to make validation offline-capable,
# like the oci:// deps above. Re-run after every `helm dependency build`, which
# restores the tarball from the cache. COPYFILE_DISABLE=1 keeps macOS' bsdtar
# from adding AppleDouble `._<name>` entries, which helm rejects ("chart
# illegally contains content outside the base directory"); no-op elsewhere.
strip-remote-schemas: ## Remove vendored subchart schemas with remote $refs (offline validation)
	@for tgz in charts/*/charts/*.tgz; do \
		[ -e "$$tgz" ] || continue; \
		name=$$(tar -tzf "$$tgz" 2>/dev/null | head -1 | cut -d/ -f1); \
		[ -n "$$name" ] || continue; \
		tar -xzOf "$$tgz" "$$name/values.schema.json" 2>/dev/null \
			| grep -q '"$$ref"[[:space:]]*:[[:space:]]*"http' || continue; \
		printf 'deps: stripping values.schema.json with remote $$refs from %s\n' "$$tgz"; \
		tmp=$$(mktemp -d ./.strip-schema.XXXXXX) || exit 1; \
		tar -xzf "$$tgz" -C "$$tmp" \
			&& rm -f "$$tmp/$$name/values.schema.json" \
			&& (cd "$$tmp" && COPYFILE_DISABLE=1 tar -czf stripped.tgz "$$name") \
			&& mv "$$tmp/stripped.tgz" "$$tgz" \
			|| { rm -rf "$$tmp"; exit 1; }; \
		rm -rf "$$tmp"; \
	done

### CHARTS
# Operator chart pins ("Pulled:" on install is a content-cache hit, not a
# download). Bump to upgrade; overridable per-invocation, e.g.
# `make install-cert-manager CERT_MANAGER_VERSION=v1.21.0`.
CERT_MANAGER_VERSION ?= v1.20.1
CNPG_CHART_VERSION ?= 0.29.0

install-cert-manager: ## Install cert-manager $(CERT_MANAGER_VERSION) (cluster-wide, incl. CRDs; no-op when that version is deployed)
	@if helm list -n cert-manager --deployed -o yaml 2>/dev/null | grep -q "chart: cert-manager-$(CERT_MANAGER_VERSION)"; then \
		printf 'cert-manager %s already deployed, skipping\n' "$(CERT_MANAGER_VERSION)"; \
	else \
		helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version $(CERT_MANAGER_VERSION) -n cert-manager --create-namespace --set crds.enabled=true; \
	fi

install-metrics-server: ## Install metrics-server and patch args for local KIND kubelets
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	@if ! kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-insecure-tls'; then \
	  kubectl -n kube-system patch deployment metrics-server --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'; \
	fi
	@if ! kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP'; then \
	  kubectl -n kube-system patch deployment metrics-server --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP"}]'; \
	fi
	kubectl -n kube-system rollout status deployment/metrics-server


### CLOUDNATIVE POSTGRES-OPERATOR
ifeq ($(STAGE),openshift)
  CNPG_SECURITY_FLAGS := --set containerSecurityContext.runAsUser=null --set containerSecurityContext.runAsGroup=null
else
  CNPG_SECURITY_FLAGS :=
endif

install-cnpg-operator: ## Install CloudNativePG operator $(CNPG_CHART_VERSION) in "cnpg-system" (no-op when that version is deployed)
	@if helm list -n cnpg-system --deployed -o yaml 2>/dev/null | grep -q "chart: cloudnative-pg-$(CNPG_CHART_VERSION)"; then \
		printf 'cloudnative-pg chart %s already deployed, skipping\n' "$(CNPG_CHART_VERSION)"; \
	else \
		helm upgrade --install cloudnative-pg oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg --version $(CNPG_CHART_VERSION) \
		  -n cnpg-system --create-namespace \
		  --set config.clusterWide=true \
		  $(CNPG_SECURITY_FLAGS) \
		  --wait --timeout 5m; \
	fi

reset-cnpg-operator: ## Remove CloudNativePG operator and CRDs (destructive)
	helm uninstall cloudnative-pg -n cnpg-system || true
	@crds=$$(kubectl get crd -o name | grep postgresql.cnpg.io || true); \
	if [ -n "$$crds" ]; then \
	  kubectl delete $$crds --ignore-not-found=true; \
	else \
	  echo "No CNPG CRDs found"; \
	fi

uninstall-cnpg-operator: ## Uninstall only the CNPG operator release (keep CRDs)
	helm uninstall cloudnative-pg -n cnpg-system || true

### LINTING/VALIDATION ###
lint: ## Helm lint subcharts and umbrella
	# Strict lint of zeta-guard subchart against demo values — validates schema and catches deprecated APIs
	helm lint charts/zeta-guard --strict -f charts/zeta-guard/values-demo.yaml \
		--set authserver.admin.password=dummy \
		--set authserver.genesisHash=dummy \
		--set authserver.smcbHashingPepper=dummy
	helm lint . --with-subcharts

template-demo: ## Render zeta-guard chart with demo values and validate YAML structure
	helm template zeta-guard charts/zeta-guard \
	  -f charts/zeta-guard/values-demo.yaml \
	  --set authserver.admin.password=dummy \
	  --set authserver.genesisHash=dummy \
	  --set authserver.smcbHashingPepper=dummy \
	  | yamllint -c .yamllint.yaml -

### RENDERING ###
template: deps ## Render manifests to stdout
	helm template $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) --namespace $(NAMESPACE) \
		--set-string "zeta-guard.authserver.admin.password=__template__" \
		--set-string "zeta-guard.authserver.genesisHash=__template__" \
		--set-string "zeta-guard.authserver.smcbHashingPepper=__template__"

template--debug: deps ## Render manifests to stdout with Helm debug output
	helm template $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) --namespace $(NAMESPACE) \
		--set-string "zeta-guard.authserver.admin.password=__template__" \
		--set-string "zeta-guard.authserver.genesisHash=__template__" \
		--set-string "zeta-guard.authserver.smcbHashingPepper=__template__" \
		--debug

render: rendered.yaml ## Generate rendered.yaml from the chart

rendered.yaml: FORCE
	helm template $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) --namespace $(NAMESPACE) \
		--set-string "zeta-guard.authserver.admin.password=__rendered__" \
		--set-string "zeta-guard.authserver.genesisHash=__rendered__" \
		--set-string "zeta-guard.authserver.smcbHashingPepper=__rendered__" > $@

yamllint: rendered.yaml ## Lint rendered.yaml with yamllint
	yamllint -c .yamllint.yaml rendered.yaml


### CERTIFICATE ADOPTION ###
# One-time migration: pre-existing namespaces hold Certificates that
# ingress-shim created from the (now removed) master-Ingress annotations.
# The chart now declares them explicitly (templates/certificate.yaml), and
# helm refuses to manage objects lacking its ownership metadata. Adopt them:
# stamp the meta.helm.sh annotations + managed-by label, and strip the stale
# ownerReference to the Ingress — otherwise ingress-shim garbage-collects the
# adopted object once the Ingress annotations are gone. Metadata-only; the TLS
# Secret is untouched, no certificate is reissued. Idempotent; no-ops when the
# object is absent (fresh namespace), already helm-owned, or the CRD missing.
adopt-certificates:
	@for cert in zeta-guard-tls zeta-guard-admin-tls; do \
		kubectl get certificate -n $(NAMESPACE) $$cert >/dev/null 2>&1 || continue; \
		owner=$$(kubectl get certificate -n $(NAMESPACE) $$cert \
			-o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}'); \
		if [ -z "$$owner" ]; then \
			printf 'Adopting pre-existing Certificate %s into release %s\n' "$$cert" "$(RELEASE)"; \
			kubectl patch certificate -n $(NAMESPACE) $$cert --type=json \
				-p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true; \
			kubectl annotate --overwrite certificate -n $(NAMESPACE) $$cert \
				meta.helm.sh/release-name=$(RELEASE) \
				meta.helm.sh/release-namespace=$(NAMESPACE); \
			kubectl label --overwrite certificate -n $(NAMESPACE) $$cert \
				app.kubernetes.io/managed-by=Helm; \
		elif [ "$$owner" != "$(RELEASE)" ]; then \
			printf 'ERROR: Certificate %s is owned by helm release %s, expected %s\n' \
				"$$cert" "$$owner" "$(RELEASE)" >&2; \
			exit 1; \
		fi; \
	done


### DRY-RUN ###
dry-run: deps adopt-certificates ## Server-side dry-run of the real `helm upgrade` (same engine as `deploy`)
	# Use helm's own server-side dry-run rather than `helm template | kubectl apply
	# --dry-run=server`: the release is helm-managed (no kubectl last-applied
	# annotation), so kubectl's 3-way merge can't drop fields removed from the
	# template — it merges the new manifest onto the live object, which falsely
	# trips mutually-exclusive-field validation (e.g. swapping a probe handler
	# httpGet → tcpSocket reports "more than 1 handler type"). helm diffs the
	# previous *release* manifest against the new one, so removals apply cleanly.
	helm upgrade --install $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) -n $(NAMESPACE) \
		--set-string "zeta-guard.authserver.admin.password=__dryrun__" \
		--set-string "zeta-guard.authserver.genesisHash=__dryrun__" \
		--set-string "zeta-guard.authserver.smcbHashingPepper=__dryrun__" \
		--dry-run=server


### DEPLOYMENT ###
deploy: deps ## Install/upgrade the release and wait for readiness
ifeq ($(filter $(STAGE),local openshift),$(STAGE))
	$(MAKE) install-cert-manager
ifeq ($(DB_MODE),cloudnative)
	$(MAKE) install-cnpg-operator
endif
endif
ifeq ($(STAGE),achelos)
	@OWNER=$$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.clusterIP=="$(ZETA_CERT_VALIDATION_MOCK_CLUSTER_IP)")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v '^$(NAMESPACE)/zeta-cert-validation-mock$$' || true); \
	if [ -n "$$OWNER" ]; then \
		echo "ERROR: achelos OCSP mock ClusterIP $(ZETA_CERT_VALIDATION_MOCK_CLUSTER_IP) is already used by:" >&2; \
		echo "$$OWNER" >&2; \
		exit 1; \
	fi
endif
	$(MAKE) adopt-certificates
	helm upgrade --install $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) -n $(NAMESPACE) --rollback-on-failure --render-subchart-notes --timeout 10m
	$(MAKE) dry-run-security-restricted

deploy-debug: deps adopt-certificates ## Install/upgrade the release with debug output (wait + timeout)
	helm upgrade --install $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) -n $(NAMESPACE) --rollback-on-failure --render-subchart-notes --timeout 10m --debug

### CONFIGURATION ###
generate-main-and-backend: ## Generates main.tf and backend depending on k8s usage
	cd terraform/authserver && \
	STAGE=$(STAGE) NAMESPACE=$(NAMESPACE) TF_VAR_use_kubernetes=$(TF_VAR_use_kubernetes) TF_VAR_config_path=$(TF_VAR_config_path) \
	./generate-main-and-backend.sh

config-init: ## Run generate-main-and-backend and initialise terraform backend
	$(MAKE) generate-main-and-backend
	terraform -chdir=$(TF_PATH) init \
		-backend-config=environments/$(STAGE).backend.hcl \
		-reconfigure

config: ## Configure deployed authserver through terraform
	$(MAKE) config-init
	# apply, retried: right after deploy the authserver may not serve the
	# admin API yet. No sleep — one attempt takes seconds (state refresh)
	# -parallelism=1: to avoid concurrently races (Hibernate StaleObjectStateException / HTTP 500)
	@for i in 1 2 3 4 5; do \
		terraform -chdir=$(TF_PATH) apply \
			-parallelism=1 \
			-var-file=../../$(TF_VARS) \
			-auto-approve && exit 0; \
		printf 'make config: terraform apply failed (attempt %s/5)%s\n' \
			"$$i" "$$( [ $$i -lt 5 ] && echo ', retrying' )"; \
	done; exit 1

config-plan: ## List changes that would be made to the stage (by make config); set PLAN_OUT=<file> to save the plan
	$(MAKE) config-init
	# plan (list changes against current tf-state; skip external scripts).
	# With PLAN_OUT=<file> the plan is also saved to a file, which `make config-show-plan PLAN_OUT=<file>` can render
	# as a plain-text diff for review.
	terraform -chdir=$(TF_PATH) plan \
    	-var-file=../../$(TF_VARS) \
    	-var="skip_external_resources=true" \
    	$(if $(strip $(PLAN_OUT)),-out=$(PLAN_OUT))

config-show-plan: ## Render a plan file saved by config-plan as a plain-text diff to stdout; needs PLAN_OUT=<file>
	@test -n "$(strip $(PLAN_OUT))" || { echo "PLAN_OUT is required: first 'make config-plan PLAN_OUT=<file>', then 'make config-show-plan PLAN_OUT=<file>'"; exit 1; }
	terraform -chdir=$(TF_PATH) show -no-color $(PLAN_OUT)

config-import: ## For development and troubleshooting only - imports configuration not yet managed by terraform
	$(MAKE) config-init
	# import
	terraform -chdir=$(TF_PATH) import \
		  -var-file=../../$(TF_VARS) \
		  -var="skip_external_resources=true" \
		  keycloak_realm.pdp_realm zeta-guard \
		  || echo "Realm not found or cannot be imported, will be created on apply";


### STATUS ###
status: ## Show Helm release status in the namespace
	helm status $(RELEASE) -n $(NAMESPACE)

notes: ## Show only the ZETA env overview block from the release NOTES
	@overview=$$(helm get notes $(RELEASE) -n $(NAMESPACE) | awk '/^=+ ZETA ENV OVERVIEW =+$$/{f=1} f; /^=+ END ZETA ENV OVERVIEW =+$$/{f=0}'); \
	if [ -n "$$overview" ]; then printf '%s\n' "$$overview"; \
	else \
		echo "No ZETA ENV OVERVIEW markers in the stored NOTES of release $(RELEASE) —"; \
		echo "it was deployed before templates/NOTES.txt gained them. Redeploy this stage"; \
		echo "to enable 'make notes'; until then 'make status' shows the full NOTES."; \
	fi

versions: ## Show deployed component images and versions
	@echo "=== Deployed images in $(NAMESPACE) ==="
	@kubectl -n $(NAMESPACE) get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.initContainers[*]}  init: {.image}{"\n"}{end}{range .spec.containers[*]}  container: {.image}{"\n"}{end}{end}' | sed 's/^\([a-zA-Z][a-zA-Z0-9_-]*\)-[a-f0-9]\{1,\}-[a-z0-9]\{5\}$$/\1/'

versions-debug: ## Show deployed components with all images and digests
	@echo "=== Deployed images in $(NAMESPACE) ==="
	@kubectl -n $(NAMESPACE) get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.initContainerStatuses[*]}  init: {.image}{"\n"}        {.imageID}{"\n"}{end}{range .status.containerStatuses[*]}  container: {.image}{"\n"}            {.imageID}{"\n"}{end}{end}'


release-versions: ## Show component image tags a release was built on, from git (usage: make release-versions TAG=1.2.2)
	@tag="$(TAG)"; \
	if [ -z "$$tag" ]; then \
	  echo "Usage: make release-versions TAG=<git-tag>"; \
	  echo "Available tags: $$(git tag --sort=-v:refname | grep -E '^[0-9]' | tr '\n' ' ')"; \
	  exit 1; \
	fi; \
	zg="$$tag:charts/zeta-guard/values.yaml"; \
	echo "=== Component image tags for $$tag (sub-chart values.yaml @ git tag) ==="; \
	for pair in authserver:keycloak-zeta pepproxy:ngx_pep provisioning-processor:provisioning-processor keychain-generator:keychain-generator telemetry-gateway:zeta-telemetry-gateway; do \
	  name=$$(echo "$$pair" | cut -d: -f1); repo=$$(echo "$$pair" | cut -d: -f2); \
	  v=$$(git show "$$zg" 2>/dev/null | grep -A3 "repository:.*$$repo" | grep -m1 'tag:' | sed -E 's/.*tag: *"?([^"]*)"?.*/\1/'); \
	  printf '  %-24s %s\n' "$$name" "$${v:-n/a}"; \
	done; \
	v=$$(git show "$$zg" 2>/dev/null | grep -A3 'repository:.*opa' | grep -m1 'tag:' | sed -E 's/.*tag: *"?([^"]*)"?.*/\1/'); \
	printf '  %-24s %s\n' opa "$${v:-n/a}"; \
	for pair in testfachdienst:testfachdienst tiger-proxy:tiger-proxy testdriver:test-driver nativedriver:native-driver exauthsim:exauthsim hsm-sim:hsmsim; do \
	  name=$$(echo "$$pair" | cut -d: -f1); dir=$$(echo "$$pair" | cut -d: -f2); \
	  v=$$(git show "$$tag:charts/$$dir/values.yaml" 2>/dev/null | grep -m1 'tag:' | sed -E 's/.*tag: *"?([^"]*)"?.*/\1/'); \
	  printf '  %-24s %s\n' "$$name" "$${v:-n/a}"; \
	done


### UNINSTALL / CLEAN ###
uninstall: ## Uninstall the release from the namespace
	# Delete CNPG Clusters first so finalizers resolve before helm uninstall, else the release sticks in `uninstalling`.
	# notification-db has resource-policy: keep (helm won't delete it) so it MUST be removed here.
	kubectl delete cluster.postgresql.cnpg.io keycloak-db notification-db -n $(NAMESPACE) --ignore-not-found=true --wait=true --timeout=2m || true
	helm uninstall $(RELEASE) -n $(NAMESPACE) --wait --timeout 5m || true
	# Safety net: drop any stuck release record so the next `helm upgrade --install` isn't blocked with "no deployed releases"
	kubectl -n $(NAMESPACE) delete secret -l owner=helm,name=$(RELEASE) --ignore-not-found=true
	kubectl delete pvc -l cnpg.io/cluster=keycloak-db -n $(NAMESPACE) --ignore-not-found=true
	kubectl delete pvc -l cnpg.io/cluster=notification-db -n $(NAMESPACE) --ignore-not-found=true
	kubectl delete secret tfstate-default-state -n $(NAMESPACE) --ignore-not-found=true
	$(MAKE) proxy-down

clean: ## Remove the generated rendered.yaml, terraform files and orphaned packaged subcharts
	rm -f rendered.yaml
	rm -rf $(TF_PATH)/.terraform $(TF_PATH)/terraform.tfstate* $(TF_PATH)/.terraform.lock.hcl $(TF_PATH)/main.tf $(TF_PATH)/providers.tf
	@find $(TF_PATH)/environments -type f -name '*.backend.hcl' ! -name 'demo.backend.hcl' -delete
	@for tgz in charts/*.tgz; do \
		[ -e "$$tgz" ] || continue; \
		name=$$(tar -tzf "$$tgz" 2>/dev/null | head -1 | cut -d/ -f1); \
		if [ -n "$$name" ] && [ ! -d "charts/$$name" ] && ! grep -q "name: $$name" Chart.yaml; then \
			printf 'clean: removing orphaned packaged subchart %s (name=%s)\n' "$$tgz" "$$name" 1>&2; \
			rm -f "$$tgz"; \
		fi; \
	done

trivy: ## scans a Kubernetes namespace for vulnerabilities, misconfigurations and exposed secrets. Requires trivy
	trivy k8s --severity=HIGH,CRITICAL --report summary --disable-node-collector --include-namespaces $(NAMESPACE)


##################

renew-opa-token: ## Trigger token-renewer CronJob once (simple): delete, create, then tail logs
	kubectl -n $(NAMESPACE) delete jobs.batch opa-token-renewer-once --ignore-not-found=true;
	kubectl -n $(NAMESPACE) create job opa-token-renewer-once --from=cronjob/opa-token-renewer-cronjob;
	sleep 3
	kubectl -n $(NAMESPACE) logs job/opa-token-renewer-once -f
	kubectl -n $(NAMESPACE) delete jobs.batch opa-token-renewer-once --ignore-not-found=true;

# Set correct path of the cert-files
ASL_SIGNER_CERT_FILE ?= private/certs/zeta-Guard-XXX-komp61.pem
ASL_SIGNER_KEY_FILE ?= private/certs/zeta-Guard-XXX-komp61.prv.pem
ASL_ISSUER_CERT_FILE ?= private/certs/GEM.KOMP-CA61-TEST-ONLY.pem

generate-asl-identity-secret: ## Create/update 'asl-identity' secret from cert/key files in $(NAMESPACE)
	@[ -f "$(ASL_SIGNER_CERT_FILE)" ] || (echo "Missing ASL_SIGNER_CERT_FILE: $(ASL_SIGNER_CERT_FILE)" && exit 1)
	@[ -f "$(ASL_SIGNER_KEY_FILE)" ] || (echo "Missing ASL_SIGNER_KEY_FILE: $(ASL_SIGNER_KEY_FILE)" && exit 1)
	@[ -f "$(ASL_ISSUER_CERT_FILE)" ] || (echo "Missing ASL_ISSUER_CERT_FILE: $(ASL_ISSUER_CERT_FILE)" && exit 1)
	@echo "creating secret asl-identity"
	@kubectl -n $(NAMESPACE) create secret generic asl-identity \
	  --from-file=signer-cert=$(ASL_SIGNER_CERT_FILE) \
	  --from-file=signer-key=$(ASL_SIGNER_KEY_FILE) \
	  --from-file=issuer-cert=$(ASL_ISSUER_CERT_FILE) \
	  --dry-run=client -o yaml | kubectl apply -f -

# Requires env vars DOCKER_USER, DOCKER_USER and DOCKER_PASSWORD to be set. (e.g. in .envrc.local)
# Auto-detect HOST_IP (override by exporting HOST_IP if needed)
HOST_IP ?= $(shell (ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || ip -4 route get 1 2>/dev/null | awk '{print $$7; exit}') )
KIND_CONFIG ?= kind-local.yaml
# Auto-detect ingress hostnames from local values (ingress-related keys), fallback to zeta-kind.local.
# Override manually only when needed, e.g. KIND_INGRESS_HOSTS="zeta-kind.local my-alias.local".
KIND_VALUES_FILE ?= $(firstword $(wildcard $(VALUES_DIR)values.local.yaml private/values.local.yaml local-test/values.local.yaml))
KIND_INGRESS_HOSTS_AUTO := $(strip $(shell \
	if [ -n "$(KIND_VALUES_FILE)" ] && [ -f "$(KIND_VALUES_FILE)" ]; then \
	  awk '\
	    /ingressRulesHost:|adminHostname:|hostname:|zetaBaseUrl:|wellKnownBase:|requiredAudience:|pepIssuer:/ { \
	      line=$$0; sub(/^[^:]*:[[:space:]]*/, "", line); gsub(/["'\'',]/, "", line); \
	      sub(/^https?:\/\//, "", line); sub(/\/.*/, "", line); sub(/:.*/, "", line); \
	      if (line ~ /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$$/) print line; \
	    }' "$(KIND_VALUES_FILE)" | sort -u | tr '\n' ' '; \
	fi))
KIND_INGRESS_HOSTS ?= $(if $(KIND_INGRESS_HOSTS_AUTO),$(KIND_INGRESS_HOSTS_AUTO),zeta-kind.local)
KIND_INGRESS_HOSTS_ESCAPED := $(shell printf '%s' "$(KIND_INGRESS_HOSTS)" | sed 's/[\/&]/\\&/g')

k3s:
	@kubectl config current-context | grep -q k3s || (echo "current context should have k3s in its name" && exit 1)
	@[ -n "$$DOCKER_REGISTRY" ] || (echo "DOCKER_REGISTRY env var not set" && exit 1)
	@[ -n "$$DOCKER_USER" ] || (echo "DOCKER_USER env var not set" && exit 1)
	@[ -n "$$DOCKER_PASSWORD" ] || (echo "DOCKER_PASSWORD env var not set" && exit 1)
	kubectl create ns zeta-local || :
	$(MAKE) create-secrets
	$(MAKE) generate-asl-identity-secret
	$(MAKE) deploy stage=k3s
	$(MAKE) config stage=k3s

k3s-down:
	@kubectl config current-context | grep -q k3s || (echo "current context should have k3s in its name" && exit 1)
	$(MAKE) uninstall stage=k3s

myip: ## Print the auto-detected HOST_IP (LAN IP used for CoreDNS / NetworkPolicy)
	@echo $(HOST_IP)

kind-up: ##! Create KIND cluster, patch CoreDNS, create ns and required secrets (requires private/)
	@[ -n "$(HOST_IP)" ] || (echo "HOST_IP not detected. Export HOST_IP=192.168.x.y and retry." && exit 1)
	@[ -n "$(KIND_INGRESS_HOSTS)" ] || (echo "KIND_INGRESS_HOSTS must not be empty." && exit 1)
	@[ -n "$$DOCKER_USER" ] || (echo "DOCKER_USER env var not set" && exit 1)
	@[ -n "$$DOCKER_PASSWORD" ] || (echo "DOCKER_PASSWORD env var not set" && exit 1)
	@[ -f "$(KIND_CONFIG)" ] || (echo "KIND_CONFIG file not found: $(KIND_CONFIG)" && exit 1)
	kind create cluster --name zeta-local --config $(KIND_CONFIG)
	sed -e "s/__HOST_IP__/$(HOST_IP)/g" \
		-e "s/__KIND_INGRESS_HOSTS__/$(KIND_INGRESS_HOSTS_ESCAPED)/g" \
 		private/kind/custom-coredns.template.yaml | kubectl apply -f -
	kubectl -n kube-system rollout restart deploy/coredns
	kubectl create namespace zeta-local || true
	# Disable Pod Security restrictions locally (remove any PSA labels)
	#$(MAKE) security-restricted
	$(MAKE) create-secrets
	$(MAKE) install-cert-manager
	$(MAKE) install-metrics-server
	$(MAKE) install-cnpg-operator
	@echo "kind-up completed. HOST_IP=$(HOST_IP) KIND_CONFIG=$(KIND_CONFIG)"

# make sure to hide secrets from output when insecurely passing them as args, i.e. @
create-secrets:
	kubectl -n $(NAMESPACE) delete secret gitlab-registry-credentials-zeta-group --ignore-not-found=true
	@echo "create secret gitlab-registry-credentials-zeta-group"
	@kubectl -n $(NAMESPACE) create secret docker-registry gitlab-registry-credentials-zeta-group \
	  --docker-server=$(DOCKER_REGISTRY) \
	  --docker-username=$(DOCKER_USER) \
	  --docker-password=$(DOCKER_PASSWORD) \
	  --docker-email=k8s-admin@example.com
	kubectl -n $(NAMESPACE) delete secret opa-bearer --ignore-not-found=true
	@echo "create secret opa-bearer"
	@TOKEN="$$DOCKER_USER:$$DOCKER_PASSWORD"; kubectl -n $(NAMESPACE) create secret generic opa-bearer --from-literal=token="$$TOKEN"

kind-down: ##! Delete KIND cluster
	kind delete cluster --name zeta-local

SQUID_MANIFEST := private/proxy

proxy-up: ##! Deploy Squid forward proxy in KIND/OpenShift cluster for local proxy testing
	kubectl apply -n $(NAMESPACE) -f $(SQUID_MANIFEST)
	@if kubectl api-resources 2>/dev/null | grep -q securitycontextconstraints; then \
	  echo "OpenShift detected — granting anyuid SCC to squid-proxy ..."; \
	  if command -v oc >/dev/null 2>&1; then \
	    eval "$$(crc oc-env)"; \
	    oc adm policy add-scc-to-user anyuid -z squid-proxy -n $(NAMESPACE); \
	  else \
	    kubectl create rolebinding squid-proxy-anyuid \
	      --clusterrole=system:openshift:scc:anyuid \
	      --serviceaccount=$(NAMESPACE):squid-proxy \
	      -n $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -; \
	  fi; \
	fi
	kubectl -n $(NAMESPACE) rollout status deploy/squid-proxy --timeout=60s
	@echo ""
	@echo "Squid running: http://squid-proxy.$(NAMESPACE).svc.cluster.local:3128"
	@echo ""
	@echo "Enable proxy values in values.$(STAGE).yaml (uncomment httpsProxy/httpProxy),"
	@echo "then: make deploy && make proxy-verify"

proxy-down: ##! Remove Squid forward proxy from KIND/OpenShift cluster
	kubectl delete -n $(NAMESPACE) -f $(SQUID_MANIFEST) --ignore-not-found
	@if kubectl api-resources 2>/dev/null | grep -q securitycontextconstraints; then \
	  if command -v oc >/dev/null 2>&1; then \
	    eval "$$(crc oc-env)"; \
	    oc adm policy remove-scc-from-user anyuid -z squid-proxy -n $(NAMESPACE) 2>/dev/null || true; \
	  else \
	    kubectl delete rolebinding squid-proxy-anyuid -n $(NAMESPACE) --ignore-not-found; \
	  fi; \
	fi
	@echo "Squid removed."

proxy-verify: ##! Verify that the PEP routes outbound traffic through Squid (requires proxy-up + deploy)
	@echo "=== Env vars in PEP container ==="
	kubectl exec -n $(NAMESPACE) deploy/pep-deployment -- env | grep -i proxy || echo "(no PROXY vars set)"
	@echo ""
	@echo "=== nginx.conf env directives ==="
	kubectl exec -n $(NAMESPACE) deploy/pep-deployment -- \
	  sh -c 'grep "^env" /etc/nginx/nginx.conf' || true
	@echo ""
	@echo "=== Squid access log (last 20 lines) ==="
	kubectl logs -n $(NAMESPACE) deploy/squid-proxy --tail=20

dry-run-security-restricted: ## Test PSS violations without modifying namespace.
	kubectl label --dry-run=server --overwrite ns $(NAMESPACE) \
	  pod-security.kubernetes.io/enforce=restricted \
	  pod-security.kubernetes.io/enforce-version=v1.32

security-restricted: ## Enable Pod Security Standard 'restricted' on namespace (with warn/audit)
	kubectl label --overwrite ns $(NAMESPACE) \
	  pod-security.kubernetes.io/enforce=restricted \
	  pod-security.kubernetes.io/enforce-version=v1.32 \
	  pod-security.kubernetes.io/warn=restricted \
	  pod-security.kubernetes.io/warn-version=v1.32 \
	  pod-security.kubernetes.io/audit=restricted \
	  pod-security.kubernetes.io/audit-version=v1.32
	@echo "PSA 'restricted' enabled for namespace zeta-local."

security-disable: ## Remove PSA labels from zeta-local namespace
	kubectl label ns $(NAMESPACE) \
	  pod-security.kubernetes.io/enforce- \
	  pod-security.kubernetes.io/enforce-version- \
	  pod-security.kubernetes.io/warn- \
	  pod-security.kubernetes.io/audit- \
	  --overwrite || true
	@echo "PSA labels removed from namespace $(NAMESPACE)."

show-label: ## labels (e.g. pod-security) on namespace
	kubectl get ns $(NAMESPACE) --show-labels


history:
	helm history $(RELEASE) -n $(NAMESPACE)

rollback:
	helm rollback $(RELEASE) 0 -n $(NAMESPACE)
