#!/usr/bin/env bash
set -e

TEMPLATE_DIR="templates"
TARGET_DIR="."
ENV_DIR="environments"
MAIN_TF_TPL="$TEMPLATE_DIR/main.tf.tpl"
PROVIDERS_TF_TPL="$TEMPLATE_DIR/providers.tf.tpl"
BACKEND_K8S_TPL="$TEMPLATE_DIR/backend.k8s.tpl"
BACKEND_LOCAL_TPL="$TEMPLATE_DIR/backend.local.tpl"
MODE_ASSERT_K8S_TPL="$TEMPLATE_DIR/mode-assert.k8s.tpl"
MODE_ASSERT_LOCAL_TPL="$TEMPLATE_DIR/mode-assert.local.tpl"
MAIN_TF="$TARGET_DIR/main.tf"
PROVIDERS_TF="$TARGET_DIR/providers.tf"
MODE_ASSERT_TF="$TARGET_DIR/mode-assert.tf"

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
    MODE_ASSERT_FILE="$MODE_ASSERT_K8S_TPL"
else
    BACKEND_BLOCK_FILE="$BACKEND_LOCAL_TPL"
    MODE_ASSERT_FILE="$MODE_ASSERT_LOCAL_TPL"
fi

# generate main.tf
cp "$MAIN_TF_TPL" "$MAIN_TF"
substitute_placeholder "$MAIN_TF" "BACKEND_BLOCK" "$BACKEND_BLOCK_FILE"
echo "Generated $MAIN_TF (use_kubernetes=$USE_K8S)"

# generate providers.tf
cp "$PROVIDERS_TF_TPL" "$PROVIDERS_TF"
echo "Generated $PROVIDERS_TF (use_kubernetes=$USE_K8S)"

# generate mode-assert.tf — asserts that var.use_kubernetes matches the mode the
# files were generated for. It holds no kubernetes_* blocks — the credentials
# come from TF_VAR_keycloak_* only (see variables.tf).
cp "$MODE_ASSERT_FILE" "$MODE_ASSERT_TF"
echo "Generated $MODE_ASSERT_TF (use_kubernetes=$USE_K8S)"

# Migration cleanup: credentials.tf used to be generated (and gitignored) and
# held `data "kubernetes_secret_v1" "keycloak_admin"`. The credentials no longer
# come from Terraform, so a copy left over in an existing working tree would
# silently reintroduce that data source — and with it the admin password in the
# state. Drop this block once no tree predates the change.
rm -f "$TARGET_DIR/credentials.tf"
rm -f "$TARGET_DIR/sekidp-secret.tf"

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

# Block substitution indents only the first line of a multi-line block, so the
# generated files are not canonically formatted. Normalise them here to keep
# `terraform fmt -check` clean across the repository.
if command -v terraform >/dev/null 2>&1; then
    terraform fmt "$TARGET_DIR" >/dev/null
fi
