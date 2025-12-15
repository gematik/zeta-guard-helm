RELEASE ?= zeta-testenv
NAMESPACE ?= zeta
# Prefer private/ if it exists; otherwise fallback to local-test/
ifeq ($(wildcard private/),)
  VALUES_DIR := local-test/
else
  VALUES_DIR := private/
endif
VALUES ?= $(VALUES_DIR)values.yaml
# Optional single-parameter env selection: `make deploy stage=cd`
# Derives: RELEASE=zeta-testenv-<stage>, NAMESPACE=zeta-<stage>, VALUES=values.<stage>.yaml
STAGE := $(strip $(stage))
ifneq ($(STAGE),)
  RELEASE := $(RELEASE)-$(STAGE)
  NAMESPACE := zeta-$(STAGE)
  VALUES := $(VALUES_DIR)values.$(STAGE).yaml
endif
LOCK ?= Chart.lock
SUBCHARTS := $(wildcard charts/*/Chart.yaml)
TF_PATH := terraform/authserver
TF_VAR_config_path ?= "~/.kube/config"

ifeq ($(strip $(SMB_KEYSTORE_PW_FILE)),)
$(error SMB_KEYSTORE_PW_FILE must not be empty)
endif

ifeq ($(strip $(SMB_KEYSTORE_FILE_B64)),)
$(error SMB_KEYSTORE_FILE_B64 must not be empty)
endif

HELM_EXTRA_VALUES_PARAMS=--set-file "zeta-guard.authserver.smcb_keystore.password=${SMB_KEYSTORE_PW_FILE}" --set-file "zeta-guard.authserver.smcb_keystore.keystore=${SMB_KEYSTORE_FILE_B64}"

.PHONY: help deps install-cert-manager lint yamllint status uninstall clean

help: ## Show available targets and variables
	@awk 'BEGIN {FS=":.*## "}; /^[a-zA-Z0-9_.-]+:.*## /{printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Vars (default-values):\n RELEASE=$(RELEASE)\n NAMESPACE=$(NAMESPACE)\n VALUES=$(VALUES)\n STAGE=$(STAGE)"


$(LOCK): Chart.yaml $(SUBCHARTS) ## Refresh vendored deps + lock when chart specs change
	@helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	@helm dependency update charts/test-monitoring-service
	@helm dependency update charts/zeta-guard
	@helm dependency update .

deps: ## Vendor chart dependencies (umbrella + zeta-guard)
	@helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm repo update ingress-nginx
	helm dependency update charts/test-monitoring-service
	# Update subchart deps first (PostgreSQL via OCI in charts/zeta-guard)
	helm dependency update charts/zeta-guard
	# Then update umbrella deps
	helm dependency update .


### CHARTS
install-cert-manager:
	helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.18.2 -n cert-manager --create-namespace --set crds.enabled=true


### LINTING/VALIDATION ###
lint: ## Helm lint subcharts and umbrella
	helm lint . --with-subcharts


### RENDERING ###
template: $(LOCK) ## Render manifests to stdout
	helm template $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS)

render: rendered.yaml ## Generate rendered.yaml from the chart

rendered.yaml:
	helm template $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) > $@

yamllint: rendered.yaml ## Lint rendered.yaml with yamllint
	yamllint -c .yamllint.yaml rendered.yaml


### DRY-RUN ###
dry-run: ## Server-side dry-run apply of rendered manifests
	helm template $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) --namespace $(NAMESPACE) | kubectl apply --dry-run=server -n $(NAMESPACE) -f -


### DEPLOYMENT ###
deploy: $(LOCK) ## Install/upgrade the release (atomic + wait + timeout)
ifeq ($(STAGE),local)
	$(MAKE) install-cert-manager
endif
	# Ensure local subchart changes are packaged
	$(MAKE) deps
	helm upgrade --install $(RELEASE) . -f $(VALUES) $(HELM_EXTRA_VALUES_PARAMS) $(HELM_ARGS) -n $(NAMESPACE)  --wait --atomic --timeout 10m

### DEPLOYMENT ###
deploy-debug: $(LOCK) ## Install/upgrade the release (atomic + wait + timeout)
	helm upgrade --install $(RELEASE) . -f $(VALUES) $(HELM_ARGS) -n $(NAMESPACE) --wait --atomic --timeout 10m --debug

### CONFIGURATION ###
config: ## Configure deployed authserver through terraform
	# initialise terraform backend
	@echo "config_path = \"$(TF_VAR_config_path)\"" > terraform/authserver/environments/$(STAGE).backend.hcl
	@echo "namespace   = \"zeta-$(STAGE)\"" >> terraform/authserver/environments/$(STAGE).backend.hcl
	terraform -chdir=$(TF_PATH) init \
		-backend-config=environments/$(STAGE).backend.hcl \
		-reconfigure

	# apply
	terraform -chdir=$(TF_PATH) apply \
		-var-file=environments/common.tfvars \
		-var-file=../../$(VALUES_DIR)$(STAGE).tfvars \
		-var="keycloak_password=$(TF_VAR_keycloak_password)" \
		-auto-approve

config-plan: ## List changes that would be made to the stage (by make config)
	# initialise terraform backend
	@echo "config_path = \"$(TF_VAR_config_path)\"" > terraform/authserver/environments/$(STAGE).backend.hcl
	@echo "namespace   = \"zeta-$(STAGE)\"" >> terraform/authserver/environments/$(STAGE).backend.hcl
	terraform -chdir=$(TF_PATH) init \
		-backend-config=environments/$(STAGE).backend.hcl \
		-reconfigure

	# plan (list changes against current tf-state; skip external scripts)
	terraform -chdir=$(TF_PATH) plan \
		-var-file=environments/common.tfvars \
    	-var-file=../../$(VALUES_DIR)$(STAGE).tfvars \
    	-var="keycloak_password=$(TF_VAR_keycloak_password)" \
    	-var="skip_external_resources=true"

config-import: ## for development and troubleshooting only - imports configuration not yet managed by terraform
	@echo "config_path = \"$(TF_VAR_config_path)\"" > terraform/authserver/environments/$(STAGE).backend.hcl
	@echo "namespace   = \"zeta-$(STAGE)\"" >> terraform/authserver/environments/$(STAGE).backend.hcl

	terraform -chdir=$(TF_PATH) init \
           -backend-config=environments/$(STAGE).backend.hcl \
           -reconfigure

	terraform -chdir=$(TF_PATH) import \
		  -var-file=../../$(VALUES_DIR)$(STAGE).tfvars \
		  -var-file=environments/common.tfvars \
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

clean: ## Remove the generated rendered.yaml file
	rm -f rendered.yaml
	rm -rf $(TF_PATH)/.terraform $(TF_PATH)/terraform.tfstate* $(TF_PATH)/.terraform.lock.hcl $(TF_PATH)/environments/*.backend.hcl



##################

## Trigger token-renewer CronJob once (simple): delete, create, then tail logs
renew-opa-token:
	kubectl -n $(NAMESPACE) delete jobs.batch opa-token-renewer-once --ignore-not-found=true;
	kubectl -n $(NAMESPACE) create job opa-token-renewer-once --from=cronjob/opa-token-renewer-cronjob;
	kubectl -n $(NAMESPACE) wait --for=condition=Ready pod -l job-name=opa-token-renewer-once --timeout=60s
	kubectl -n $(NAMESPACE) logs job/opa-token-renewer-once -f
	kubectl -n $(NAMESPACE) delete jobs.batch opa-token-renewer-once --ignore-not-found=true;
