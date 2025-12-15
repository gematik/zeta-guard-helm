# How to configure ZETA Guard Authserver

## Overview

This guide describes how to configure the ZETA Guard Authserver (PDP) using Terraform 
and the provided Makefile. The Makefile supports robust CI/CD execution and optional 
admin password handling to streamline deployments and updates.

This step can be performed multiple times to configure and reconfigure the authserver 
without the need to deploy it from scratch.

> Configuration is managed via Terraform and provides both customizable and predefined settings:
> 
> Customizable properties:
> - Authserver URL
> - TLS configuration (self-signed certificates are supported)
> - ZETA Guard realm
> - PDP scopes
> 
> Predefined settings:
> - PDP scopes `zero:manage` and `zero:register` are automatically created
> - Realm token encryption is set to ES256
> - Trusted Hosts, Max Clients Limit, Consent Required Policies are removed
> - ZETA Max Clients Limit Policy added

---

## Prerequisites

- A running ZETA Guard Kubernetes cluster
- `kubectl` configured to access the cluster
- Terraform installed (version compatible with the providers)
- Make installed

> If using a pipeline, do set 
> - `TF_VAR_config_path` and 
> - `TF_VAR_keycloak_password` 
> 
> environment variables according to your setup. 

---

## Development Setup and Usage

Terraform state and credentials are managed securely within the Kubernetes cluster. The Makefile automates initialization, import, and apply steps, so manual Terraform commands are generally unnecessary.

If the Keycloak admin password is not stored in the cluster secret, it can be passed in via the Makefile as described below.

---

### Terraform Variables

Set environment-specific variables in `environments/STAGE.tfvars`. Key variables include:

```hcl
insecure_tls       = true                         # Set to true if using self-signed certificates
keycloak_url       = "https://.../auth"           # URL of the Keycloak instance
keycloak_namespace = "zeta-demo"                  # Kubernetes namespace where Keycloak runs
pdp_scopes         = ["zero:read", "zero:write"]  # Optional scope list
```

---

### Applying Configuration with Makefile

Use the Makefile to manage Terraform operations. The Makefile now performs the following automatically:

- Initializes the Terraform backend
- Applies the Terraform configuration to create or update resources

#### Basic usage

To configure an environment, run:

```shell
make config stage=demo
```

#### Passing admin password (optional)

If the Keycloak admin password is **not** stored in the Kubernetes secret, pass it as an environment variable:

```shell
make config stage=cd TF_VAR_keycloak_password=your_password
```

> If using the terminal the default path to the kubeconfig is `~/.kube/config`. 
> Set `TF_VAR_config_path` if it differs.

---

## Makefile Details

The `config` target in the Makefile performs the following:

- Echo the backend configuration appropriate to the stage (namespace and kube config path)
- Initialize the Terraform backend
- Check changes against the terraform state within the cluster
- Apply the terraform configuration to create, update and delete resources

---

## Troubleshooting

- **Terraform init fails:** Verify that `config_path` points to a valid kubeconfig file and the current context is correct (`kubectl config get-contexts`).
- **Terraform apply fails initializing Keycloak provider:**
  - Check the `keycloak_url` in your `STAGE.tfvars`.
  - Confirm the admin password is present in the cluster secret (`kubectl get secret authserver-admin -n <namespace> -o yaml`). The secret should contain base64-encoded `username` and `password` fields.
  - If the secret password is empty, pass the password via `TF_VAR_keycloak_password`.
  - If you encounter TLS certificate errors (`x509: certificate signed by unknown authority`), set `insecure_tls = true` in the tfvars or use a valid certificate.

---

## Additional Notes

- Terraform state is stored in a Kubernetes Secret within the environment namespace.
- Secret name format: `tfstate-<workspace>-state` (e.g., `tfstate-default-state`).
- The Makefile and Terraform configurations are designed for seamless CI/CD integration.

---

## Related Resources

- [Terraform Kubernetes Provider](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs)
- [Terraform Keycloak Provider](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs)
