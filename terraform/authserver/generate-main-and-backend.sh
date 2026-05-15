#!/bin/bash
set -e

TEMPLATE_DIR="templates"
TARGET_DIR="."
ENV_DIR="environments"
MAIN_TF_TPL="$TEMPLATE_DIR/main.tf.tpl"
PROVIDERS_TF_TPL="$TEMPLATE_DIR/providers.tf.tpl"
BACKEND_K8S_TPL="$TEMPLATE_DIR/backend.k8s.tpl"
BACKEND_LOCAL_TPL="$TEMPLATE_DIR/backend.local.tpl"
REQUIRED_PROVIDER_K8S_TPL="$TEMPLATE_DIR/required-provider.kubernetes.tpl"
PROVIDER_K8S_TPL="$TEMPLATE_DIR/provider.kubernetes.tpl"
MAIN_TF="$TARGET_DIR/main.tf"
PROVIDERS_TF="$TARGET_DIR/providers.tf"

USE_K8S="${TF_VAR_use_kubernetes:-true}"
STAGE="${STAGE:-local}"
NAMESPACE="${NAMESPACE:-zeta-local}"
CONFIG_PATH="${TF_VAR_config_path:-~/.kube/config}"
BACKEND_HCL="$ENV_DIR/${STAGE}.backend.hcl"

# substitute_placeholder FILE PLACEHOLDER REPLACEMENT_FILE
# Replaces {{PLACEHOLDER}} in FILE with the contents of REPLACEMENT_FILE (or removes it if empty).
substitute_placeholder() {
    local file="$1" placeholder="$2" replacement_file="$3"
    if [ -n "$replacement_file" ] && [ -s "$replacement_file" ]; then
        awk 'NR==FNR {block = block sep $0; sep="\n"; next} {sub(/\{\{'"$placeholder"'\}\}/, block)} 1' \
            "$replacement_file" "$file" > "$file.tmp"
    else
        sed "s/{{${placeholder}}}//" "$file" > "$file.tmp"
    fi
    mv "$file.tmp" "$file"
}

# select backend block
if [ "$USE_K8S" = "true" ]; then
    BACKEND_BLOCK_FILE="$BACKEND_K8S_TPL"
    K8S_REQUIRED_PROVIDER_FILE="$REQUIRED_PROVIDER_K8S_TPL"
    K8S_PROVIDER_FILE="$PROVIDER_K8S_TPL"
else
    BACKEND_BLOCK_FILE="$BACKEND_LOCAL_TPL"
    K8S_REQUIRED_PROVIDER_FILE=""
    K8S_PROVIDER_FILE=""
fi

# generate main.tf
cp "$MAIN_TF_TPL" "$MAIN_TF"
substitute_placeholder "$MAIN_TF" "BACKEND_BLOCK" "$BACKEND_BLOCK_FILE"
substitute_placeholder "$MAIN_TF" "KUBERNETES_REQUIRED_PROVIDER" "$K8S_REQUIRED_PROVIDER_FILE"
echo "Generated $MAIN_TF (use_kubernetes=$USE_K8S)"

# generate providers.tf
cp "$PROVIDERS_TF_TPL" "$PROVIDERS_TF"
substitute_placeholder "$PROVIDERS_TF" "KUBERNETES_PROVIDER_BLOCK" "$K8S_PROVIDER_FILE"
echo "Generated $PROVIDERS_TF (use_kubernetes=$USE_K8S)"

# generate backend.hcl
if [ "$USE_K8S" = "true" ]; then
    cat > "$BACKEND_HCL" <<EOF
config_path   = "$CONFIG_PATH"
namespace     = "$NAMESPACE"
EOF
else
    : > "$BACKEND_HCL"
fi
echo "Generated $BACKEND_HCL"
