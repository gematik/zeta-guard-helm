# Prefer private/ if it exists; otherwise fallback to local-test/
ifeq ($(wildcard private/),)
  VALUES_DIR := local-test/
else
  VALUES_DIR := private/
endif

# Optional single-parameter env selection: `make deploy stage=<env>`
# If not provided, default to 'local'.
STAGE := $(strip $(if $(stage),$(stage),local))

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
LOCK ?= Chart.lock
SUBCHARTS := $(wildcard charts/*/Chart.yaml)
# Database bootstrap mode for local convenience targets
DB_MODE ?= cloudnative
# Terraform config variables
TF_PATH := terraform/authserver
TF_VAR_config_path ?= "~/.kube/config"
TF_VAR_use_kubernetes ?= true

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

ifeq ($(STAGE),achelos)
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
ZETA_CERT_VALIDATION_MOCK_CLUSTER_IP := $(shell kubectl --request-timeout=3s -n $(NAMESPACE) get service zeta-cert-validation-mock -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
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
  help deps lint template-demo yamllint \
  install-cert-manager install-metrics-server install-cnpg-operator reset-cnpg-operator \
  template render dry-run \
  deploy deploy-debug \
  config config-plan config-import \
  status versions versions-debug uninstall clean \
  dry-run-security-restricted security-restricted security-disable show-label \
  generate-asl-identity-secret \
  renew-opa-token \
  kind-up kind-down \
  trivy

FORCE:

help: ## Show available targets, usage, and effective vars
	@awk 'BEGIN {FS=":.*## "}; /^[a-zA-Z0-9_.-]+:.*## /{printf "  %-25s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
ifneq ($(wildcard private/),)
	@echo
	@echo "Targets requiring private/:"
	@awk 'BEGIN {FS=":.*##! "}; /^[a-zA-Z0-9_.-]+:.*##! /{printf "  %-25s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
endif
	@echo
	@echo "Usage: make <target> [stage=<env>] [namespace=<ns>] [values=<path>]"
	@echo "       stage defaults to 'local' when omitted"
	@echo
	@echo "Vars (effective):\n RELEASE=$(RELEASE)\n NAMESPACE=$(NAMESPACE)\n VALUES=$(VALUES)\n STAGE=$(STAGE)"
	@echo
	@echo "Note:"
	@echo "  The following targets require SMB_KEYSTORE_PW_FILE and SMB_KEYSTORE_FILE_B64:"
	@echo "    deploy, deploy-debug, template, template--debug, render, dry-run"


$(LOCK): Chart.yaml $(SUBCHARTS) ## Refresh vendored deps + lock when chart specs change
	@helm dependency update charts/test-monitoring-service
	@helm dependency update charts/zeta-guard
	@helm dependency update .

deps: ## Vendor chart dependencies (umbrella + zeta-guard)
	helm dependency update charts/test-monitoring-service
	# Update subchart deps first
	helm dependency update charts/zeta-guard
	# Then update umbrella deps
	helm dependency update .


### CHARTS
install-cert-manager: ## Install or upgrade cert-manager (cluster-wide, including CRDs)
	helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.20.1 -n cert-manager --create-namespace --set crds.enabled=true

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

install-cnpg-operator: ## Install CloudNativePG operator in namespace "cnpg-system"
	helm repo add cnpg https://cloudnative-pg.github.io/charts
	helm repo update cnpg
	helm upgrade --install cloudnative-pg cnpg/cloudnative-pg \
	  -n cnpg-system --create-namespace \
	  --set config.clusterWide=true \
	  $(CNPG_SECURITY_FLAGS) \
	  --wait --timeout 5m

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
template: $(LOCK) ## Render manifests to stdout
	helm template $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) --namespace $(NAMESPACE) \
		--set-string "zeta-guard.authserver.admin.password=__template__" \
		--set-string "zeta-guard.authserver.genesisHash=__template__" \
		--set-string "zeta-guard.authserver.smcbHashingPepper=__template__"

template--debug: $(LOCK) ## Render manifests to stdout
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


### DRY-RUN ###
dry-run: ## Server-side dry-run apply of rendered manifests
	helm template $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) --namespace $(NAMESPACE) \
		--set-string "zeta-guard.authserver.admin.password=__dryrun__" \
		--set-string "zeta-guard.authserver.genesisHash=__dryrun__" \
		--set-string "zeta-guard.authserver.smcbHashingPepper=__dryrun__" \
		| kubectl apply --dry-run=server -n $(NAMESPACE) -f -


### DEPLOYMENT ###
deploy: $(LOCK) ## Install/upgrade the release and wait for readiness
ifeq ($(filter $(STAGE),local openshift),$(STAGE))
	$(MAKE) install-cert-manager
ifeq ($(DB_MODE),cloudnative)
	$(MAKE) install-cnpg-operator
endif
endif
	# Ensure local subchart changes are packaged
	$(MAKE) deps
	helm upgrade --install $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) -n $(NAMESPACE) --rollback-on-failure --timeout 10m
	$(MAKE) dry-run-security-restricted

deploy-debug: $(LOCK) ## Install/upgrade the release with debug output (wait + timeout)
	helm upgrade --install $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) -n $(NAMESPACE) --rollback-on-failure --timeout 10m --debug


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
	# apply
	terraform -chdir=$(TF_PATH) apply \
		-var-file=../../$(VALUES_DIR)$(STAGE).tfvars \
		-var="keycloak_password=$(TF_VAR_keycloak_password)" \
		-auto-approve

config-plan: ## List changes that would be made to the stage (by make config)
	$(MAKE) config-init
	# plan (list changes against current tf-state; skip external scripts)
	terraform -chdir=$(TF_PATH) plan \
    	-var-file=../../$(VALUES_DIR)$(STAGE).tfvars \
    	-var="keycloak_password=$(TF_VAR_keycloak_password)" \
    	-var="skip_external_resources=true"

config-import: ## For development and troubleshooting only - imports configuration not yet managed by terraform
	$(MAKE) config-init
	# import
	terraform -chdir=$(TF_PATH) import \
		  -var-file=../../$(VALUES_DIR)$(STAGE).tfvars \
		  -var "keycloak_password=$(TF_VAR_keycloak_password)" \
		  -var="skip_external_resources=true" \
		  keycloak_realm.pdp_realm zeta-guard \
		  || echo "Realm not found or cannot be imported, will be created on apply";


### STATUS ###
status: ## Show Helm release status in the namespace
	helm status $(RELEASE) -n $(NAMESPACE)

versions: ## Show deployed component images and versions
	@echo "=== Deployed images in $(NAMESPACE) ==="
	@kubectl -n $(NAMESPACE) get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.initContainers[*]}  init: {.image}{"\n"}{end}{range .spec.containers[*]}  container: {.image}{"\n"}{end}{end}' | sed 's/^\([a-zA-Z][a-zA-Z0-9_-]*\)-[a-f0-9]\{1,\}-[a-z0-9]\{5\}$$/\1/'

versions-debug: ## Show deployed components with all images and digests
	@echo "=== Deployed images in $(NAMESPACE) ==="
	@kubectl -n $(NAMESPACE) get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.initContainerStatuses[*]}  init: {.image}{"\n"}        {.imageID}{"\n"}{end}{range .status.containerStatuses[*]}  container: {.image}{"\n"}            {.imageID}{"\n"}{end}{end}'


### UNINSTALL / CLEAN ###
uninstall: ## Uninstall the release from the namespace
	# Delete CNPG Cluster first so its finalizer resolves before helm uninstall — otherwise helm hits its timeout and leaves the release stuck in `uninstalling`
	kubectl delete cluster.postgresql.cnpg.io keycloak-db -n $(NAMESPACE) --ignore-not-found=true --wait=true --timeout=2m || true
	helm uninstall $(RELEASE) -n $(NAMESPACE) --wait --timeout 5m || true
	# Safety net: drop any stuck release record so the next `helm upgrade --install` isn't blocked with "no deployed releases"
	kubectl -n $(NAMESPACE) delete secret -l owner=helm,name=$(RELEASE) --ignore-not-found=true
	kubectl delete pvc -l cnpg.io/cluster=keycloak-db -n $(NAMESPACE) --ignore-not-found=true
	kubectl delete secret tfstate-default-state -n $(NAMESPACE) --ignore-not-found=true
	$(MAKE) proxy-down

clean: ## Remove the generated rendered.yaml and terraform files
	rm -f rendered.yaml
	rm -rf $(TF_PATH)/.terraform $(TF_PATH)/terraform.tfstate* $(TF_PATH)/.terraform.lock.hcl $(TF_PATH)/main.tf $(TF_PATH)/providers.tf
	@find $(TF_PATH)/environments -type f -name '*.backend.hcl' ! -name 'demo.backend.hcl' -delete

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
ASL_SIGNER_CERT_FILE ?=
ASL_SIGNER_KEY_FILE ?=
ASL_ISSUER_CERT_FILE ?=

generate-asl-identity-secret: ## Create/update 'asl-identity' secret from cert/key files in $(NAMESPACE)
	@[ -f "$(ASL_SIGNER_CERT_FILE)" ] || (echo "Missing ASL_SIGNER_CERT_FILE: $(ASL_SIGNER_CERT_FILE)" && exit 1)
	@[ -f "$(ASL_SIGNER_KEY_FILE)" ] || (echo "Missing ASL_SIGNER_KEY_FILE: $(ASL_SIGNER_KEY_FILE)" && exit 1)
	@[ -f "$(ASL_ISSUER_CERT_FILE)" ] || (echo "Missing ASL_ISSUER_CERT_FILE: $(ASL_ISSUER_CERT_FILE)" && exit 1)
	kubectl -n $(NAMESPACE) create secret generic asl-identity \
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

myip:
	echo $(HOST_IP)

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

create-secrets:
	kubectl -n $(NAMESPACE) delete secret gitlab-registry-credentials-zeta-group --ignore-not-found=true
	kubectl -n $(NAMESPACE) create secret docker-registry gitlab-registry-credentials-zeta-group \
	  --docker-server=$(DOCKER_REGISTRY) \
	  --docker-username=$(DOCKER_USER) \
	  --docker-password=$(DOCKER_PASSWORD) \
	  --docker-email=k8s-admin@example.com
	kubectl -n $(NAMESPACE) delete secret opa-bearer --ignore-not-found=true
	TOKEN="$$DOCKER_USER:$$DOCKER_PASSWORD"; kubectl -n $(NAMESPACE) create secret generic opa-bearer --from-literal=token="$$TOKEN"

kind-down: ##! Delete KIND cluster
	kind delete cluster --name zeta-local

SQUID_MANIFEST := private/proxy

proxy-up: ##! Deploy Squid forward proxy in KIND/OpenShift cluster for local proxy testing
	kubectl apply -n $(NAMESPACE) -f $(SQUID_MANIFEST)
	@if kubectl api-resources 2>/dev/null | grep -q securitycontextconstraints; then \
	  echo "OpenShift detected — granting anyuid SCC to squid-proxy ..."; \
	  if command -v oc >/dev/null 2>&1; then \
  		eval $(crc oc-env) \
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
	    eval $(crc oc-env) \
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
