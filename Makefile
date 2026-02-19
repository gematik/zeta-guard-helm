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
# Anything and local stage -> Helm-managed Bitnami PostgreSQL; "operator" and local stage -> Zalando Postgres Operator
DB_MODE ?= bitnami
TF_PATH := terraform/authserver
TF_VAR_config_path ?= "~/.kube/config"

# Enforce SMB keystore vars for all targets except 'help'
ifneq ($(filter help,$(MAKECMDGOALS)),help)

ifeq ($(strip $(SMB_KEYSTORE_PW_FILE)),)
$(error SMB_KEYSTORE_PW_FILE must not be empty)
endif

ifeq ($(strip $(SMB_KEYSTORE_FILE_B64)),)
$(error SMB_KEYSTORE_FILE_B64 must not be empty)
endif

endif

HELM_EXTRA_VALUES_PARAMS=--set-file "smcb_keystore.password=${SMB_KEYSTORE_PW_FILE}" --set-file "smcb_keystore.keystore=${SMB_KEYSTORE_FILE_B64}"

.PHONY: \
  help deps lint yamllint \
  install-cert-manager install-postgres-operator install-postgres-crds reset-postgres-operator \
  template render dry-run \
  deploy deploy-debug \
  config config-plan config-import \
  status uninstall clean \
  renew-opa-token

help: ## Show available targets, usage, and effective vars
	@awk 'BEGIN {FS=":.*## "}; /^[a-zA-Z0-9_.-]+:.*## /{printf "  %-25s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Usage: make <target> [stage=<env>] [namespace=<ns>] [values=<path>]"
	@echo "       stage defaults to 'local' when omitted"
	@echo
	@echo "Vars (effective):\n RELEASE=$(RELEASE)\n NAMESPACE=$(NAMESPACE)\n VALUES=$(VALUES)\n STAGE=$(STAGE)"
	@echo
	@echo "Note:"
	@echo "  Most targets require the following environment variables to be set:"
	@echo "    - SMB_KEYSTORE_PW_FILE"
	@echo "    - SMB_KEYSTORE_FILE_B64"


$(LOCK): Chart.yaml $(SUBCHARTS) ## Refresh vendored deps + lock when chart specs change
	@helm dependency update charts/test-monitoring-service
	@helm dependency update charts/zeta-guard
	@helm dependency update .

deps: ## Vendor chart dependencies (umbrella + zeta-guard)
	helm dependency update charts/test-monitoring-service
	# Update subchart deps first (PostgreSQL via OCI in charts/zeta-guard)
	helm dependency update charts/zeta-guard
	# Then update umbrella deps
	helm dependency update .


### CHARTS
install-cert-manager: ## Install or upgrade cert-manager (cluster-wide, including CRDs)
	helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.18.2 -n cert-manager --create-namespace --set crds.enabled=true


### POSTGRES-OPERATOR
install-postgres-operator: ## Install Zalando Postgres Operator including CRDs via Helm
	helm repo add postgres-operator-charts https://opensource.zalando.com/postgres-operator/charts/postgres-operator
	helm repo update postgres-operator-charts
	helm upgrade --install postgres-operator \
	  postgres-operator-charts/postgres-operator \
	  --version 1.15.1 \
	  -n postgres-operator \
	  --create-namespace \
	  --wait \
	  --timeout 5m

install-postgres-crds: ## Manually apply Postgres Operator CRDs (emergency / recovery only)
	kubectl apply -f https://raw.githubusercontent.com/zalando/postgres-operator/v1.15.1/charts/postgres-operator/crds/postgresqls.yaml
	kubectl apply -f https://raw.githubusercontent.com/zalando/postgres-operator/v1.15.1/charts/postgres-operator/crds/operatorconfigurations.yaml
	kubectl apply -f https://raw.githubusercontent.com/zalando/postgres-operator/v1.15.1/charts/postgres-operator/crds/postgresteams.yaml

reset-postgres-operator: ## Remove Postgres Operator namespace and CRDs (destructive)
	kubectl delete ns postgres-operator --ignore-not-found=true
	kubectl delete crd \
	  postgresqls.acid.zalan.do \
	  operatorconfigurations.acid.zalan.do \
	  postgresteams.acid.zalan.do \
	  --ignore-not-found=true


### LINTING/VALIDATION ###
lint: ## Helm lint subcharts and umbrella
	helm lint . --with-subcharts


### RENDERING ###
template: $(LOCK) ## Render manifests to stdout
	helm template $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) \
	--set-string "zeta-guard.authserver.admin.password=__template__"

render: rendered.yaml ## Generate rendered.yaml from the chart

rendered.yaml:
	helm template $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) \
 	--set-string "zeta-guard.authserver.admin.password=__rendered__" \ > $@

yamllint: rendered.yaml ## Lint rendered.yaml with yamllint
	yamllint -c .yamllint.yaml rendered.yaml


### DRY-RUN ###
dry-run: ## Server-side dry-run apply of rendered manifests
	helm template $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) --namespace $(NAMESPACE) \
 	--set-string "zeta-guard.authserver.admin.password=__dryrun__" \
 	| kubectl apply --dry-run=server -n $(NAMESPACE) -f -


### DEPLOYMENT ###
deploy: $(LOCK) ## Install/upgrade the release rollback-on-failure + timeout)
ifeq ($(STAGE),local)
	$(MAKE) install-cert-manager
ifeq ($(DB_MODE),operator)
	$(MAKE) install-postgres-operator
endif
endif
	# Ensure local subchart changes are packaged
	$(MAKE) deps
	helm upgrade --install $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) -n $(NAMESPACE) --rollback-on-failure --timeout 15m

deploy-debug: $(LOCK) ## Install/upgrade the release with debug output (atomic + wait + timeout)
	helm upgrade --install $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) -n $(NAMESPACE) --rollback-on-failure --timeout 15m --debug


### CONFIGURATION ###
config: ## Configure deployed authserver through terraform
	# initialise terraform backend
	@echo "config_path = \"$(TF_VAR_config_path)\"" > terraform/authserver/environments/$(STAGE).backend.hcl
	@echo "namespace   = \"$(NAMESPACE)\"" >> terraform/authserver/environments/$(STAGE).backend.hcl
	terraform -chdir=$(TF_PATH) init \
		-backend-config=environments/$(STAGE).backend.hcl \
		-reconfigure

	# apply
	terraform -chdir=$(TF_PATH) apply \
		-var-file=../../$(VALUES_DIR)$(STAGE).tfvars \
		-var="keycloak_password=$(TF_VAR_keycloak_password)" \
		-auto-approve

config-plan: ## List changes that would be made to the stage (by make config)
	# initialise terraform backend
	@echo "config_path = \"$(TF_VAR_config_path)\"" > terraform/authserver/environments/$(STAGE).backend.hcl
	@echo "namespace   = \"$(NAMESPACE)\"" >> terraform/authserver/environments/$(STAGE).backend.hcl
	terraform -chdir=$(TF_PATH) init \
		-backend-config=environments/$(STAGE).backend.hcl \
		-reconfigure

	# plan (list changes against current tf-state; skip external scripts)
	terraform -chdir=$(TF_PATH) plan \
    	-var-file=../../$(VALUES_DIR)$(STAGE).tfvars \
    	-var="keycloak_password=$(TF_VAR_keycloak_password)" \
    	-var="skip_external_resources=true"

config-import: ## For development and troubleshooting only - imports configuration not yet managed by terraform
	@echo "config_path = \"$(TF_VAR_config_path)\"" > terraform/authserver/environments/$(STAGE).backend.hcl
	@echo "namespace   = \"$(NAMESPACE)\"" >> terraform/authserver/environments/$(STAGE).backend.hcl

	terraform -chdir=$(TF_PATH) init \
           -backend-config=environments/$(STAGE).backend.hcl \
           -reconfigure

	terraform -chdir=$(TF_PATH) import \
		  -var-file=../../$(VALUES_DIR)$(STAGE).tfvars \
		  -var "keycloak_password=$(TF_VAR_keycloak_password)" \
		  -var="skip_external_resources=true" \
		  keycloak_realm.pdp_realm zeta-guard \
		  || echo "Realm not found or cannot be imported, will be created on apply";

### STATUS ###
status: ## Show Helm release status in the namespace
	helm status $(RELEASE) -n $(NAMESPACE)


### UNINSTALL / CLEAN ###
uninstall: ## Uninstall the release from the namespace
	helm uninstall $(RELEASE) -n $(NAMESPACE) || true
	kubectl delete secret tfstate-default-state -n $(NAMESPACE) || true

clean: ## Remove the generated rendered.yaml and terraform files
	rm -f rendered.yaml
	rm -rf $(TF_PATH)/.terraform $(TF_PATH)/terraform.tfstate* $(TF_PATH)/.terraform.lock.hcl
	@find $(TF_PATH)/environments -type f -name '*.backend.hcl' ! -name 'demo.backend.hcl' -delete

trivy: ## scans a Kubernetes namespace for vulnerabilities, misconfigurations and exposed secrets. Requires trivy
	trivy k8s --severity=HIGH,CRITICAL --report summary --disable-node-collector --include-namespaces $(NAMESPACE)


##################

renew-opa-token: ## Trigger token-renewer CronJob once (simple): delete, create, then tail logs
	kubectl -n $(NAMESPACE) delete jobs.batch opa-token-renewer-once --ignore-not-found=true;
	kubectl -n $(NAMESPACE) create job opa-token-renewer-once --from=cronjob/opa-token-renewer-cronjob;
	kubectl -n $(NAMESPACE) wait --for=condition=Ready pod -l job-name=opa-token-renewer-once --timeout=60s
	kubectl -n $(NAMESPACE) logs job/opa-token-renewer-once -f
	kubectl -n $(NAMESPACE) delete jobs.batch opa-token-renewer-once --ignore-not-found=true;

# Requires env vars DOCKER_USER, DOCKER_USER and DOCKER_PASSWORD to be set. (e.g. in .envrc.local)
# Auto-detect HOST_IP (override by exporting HOST_IP if needed)
HOST_IP ?= $(shell (ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || ip -4 route get 1 2>/dev/null | awk '{print $$7; exit}') )

myip:
	echo $(HOST_IP)

kind-up: ## Create KIND cluster, patch CoreDNS, create ns and required secrets
	@[ -n "$(HOST_IP)" ] || (echo "HOST_IP not detected. Export HOST_IP=192.168.x.y and retry." && exit 1)
	@[ -n "$$DOCKER_USER" ] || (echo "DOCKER_USER env var not set" && exit 1)
	@[ -n "$$DOCKER_PASSWORD" ] || (echo "DOCKER_PASSWORD env var not set" && exit 1)
	kind create cluster --name zeta-local --config kind-local.yaml
	sed -e "s/__HOST_IP__/$(HOST_IP)/g" private/kind/custom-coredns.template.yaml | kubectl apply -f -
	kubectl -n kube-system rollout restart deploy/coredns
	kubectl create namespace zeta-local || true
	#kubectl label --overwrite ns zeta-local pod-security.kubernetes.io/enforce=restricted
	# Disable Pod Security restrictions locally (remove any PSA labels)
	kubectl label ns zeta-local \
	  pod-security.kubernetes.io/enforce- \
	  pod-security.kubernetes.io/enforce-version- \
	  pod-security.kubernetes.io/warn- \
	  pod-security.kubernetes.io/audit- \
	  --overwrite || true
	kubectl -n zeta-local delete secret gitlab-registry-credentials-zeta-group --ignore-not-found=true
	kubectl -n zeta-local create secret docker-registry gitlab-registry-credentials-zeta-group \
	  --docker-server=$(DOCKER_REGISTRY) \
	  --docker-username=$(DOCKER_USER) \
	  --docker-password=$(DOCKER_PASSWORD) \
	  --docker-email=k8s-admin@example.com
	kubectl -n zeta-local delete secret opa-bearer --ignore-not-found=true
	TOKEN="$$DOCKER_USER:$$DOCKER_PASSWORD"; kubectl -n zeta-local create secret generic opa-bearer --from-literal=token="$$TOKEN"
	$(MAKE) install-cert-manager
	$(MAKE) install-postgres-operator
	@echo "kind-up completed. HOST_IP=$(HOST_IP)"

kind-down: ## Delete KIND cluster
	kind delete cluster --name zeta-local
