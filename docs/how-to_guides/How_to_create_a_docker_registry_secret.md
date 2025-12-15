# How to create a docker-registry type secret for accessing a private registry

Kubernetes needs a personal access token (with the scope `read_registry` for 
GitLab) to access the container registry.

```shell
kubectl create secret docker-registry private-registry-credentials-zeta-group \
    -n NAMESPACE \
    --docker-server=<REGISTRY_HOST_AND_PORT> \
    --docker-username=<USERNAME> \
    --docker-password=<ACCESS_TOKEN> \
    --docker-email=<EMAIL_ADDRESS>
```

When your token expires,
you must delete the old secret before recreating it using the following command:

```shell
kubectl delete secret private-registry-credentials-zeta-group -n NAMESPACE
```

## Related sources

* [Kubernetes Reference – kubectl create secret docker-registry](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_create/kubectl_create_secret_docker-registry/)
