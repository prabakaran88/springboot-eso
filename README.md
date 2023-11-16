# springboot-argocd
Springboot CRUD Operation with External Secret Operator(ESO)

## Pre-requisites
1. Install minikube into your local machine. [Installation Guide](https://minikube.sigs.k8s.io/docs/start/)
2. Install kubectl into your local machine.[Installation Guide](https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/)
3. Install helm into your local machine.[Installation Guide](https://helm.sh/docs/intro/install/)
4. Also encourage you to install [kubectx + kubens](https://github.com/ahmetb/kubectx) to navigate Kubernetes easily.

## Vault installation
For the beginning select toolbox namespace.
```text
# namespace for Vault
kubectl create ns toolbox
kubens toolbox
```
To install Vault we will use the official [Helm chart](https://github.com/hashicorp/vault-helm) provided by HashiCorp.
```text
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault --set "server.dev.enabled=true"
```
To check if Vault is successfully installed on the Kubernetes cluster we can display a list of running pods:

```text
kubectl get pod 
NAME                                   READY   STATUS    RESTARTS   AGE
vault-0                                1/1     Running   0          25s
vault-agent-injector-9456c6d55-hx2fd   1/1     Running   0          21s
```
we need to enable port-forwarding and export Vault local address as the VAULT_ADDR environment variable:
```text
kubectl port-forward vault-0 8200

git bash
export VAULT_ADDR=http://127.0.0.1:8200
powershell
$env:VAULT_ADDR='http://127.0.0.1:8200'

vault status
vault login root
```
### Vault setup
Vault uses [Secrets Engines](https://developer.hashicorp.com/vault/docs/secrets) to store, generate, or encrypt data. The basic Secret Engine for storing static secrets is [Key-Value](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2) engine. Let’s create one sample secret that we’ll inject later into Helm Charts.
```text
# enable kv-v2 engine in Vault
vault secrets enable kv-v2

# create kv-v2 secret with two keys
vault kv put kv-v2/demo message="Will SA win semifinal?"

vault kv put kv-v2/rds_service host="postgres" name="postgres" username="admin" password="admin"

# create policy to enable reading above secret
vault policy write demo - <<EOF
path "kv-v2/data/demo" {
  capabilities = ["read"]
}
EOF

vault policy write rds_service - <<EOF
path "kv-v2/data/rds_service" {
  capabilities = ["read"]
}
EOF
```
Now we need to create a role that will authenticate ArgoCD in Vault. We said that Vault has Secrets Engines component. [Auth methods](https://developer.hashicorp.com/vault/docs/auth) are another type of component in Vault but for assigning identity and a set of policies to user/app. As we are using Kubernetes platforms, we need to focus on [Kubernetes Auth Method](https://developer.hashicorp.com/vault/docs/auth/kubernetes) to configure Vault accesses. Let’s configure this auth method.

```text
# enable Kubernetes Auth Method
vault auth enable kubernetes

# configure Kubernetes Auth Method by logging inside vault container
kubectl exec -it vault-0 sh
vault write auth/kubernetes/config token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt disable_local_ca_jwt=true
# create authenticate Role for External Secret Operator(ESO)
vault write auth/kubernetes/role/eso-role bound_service_account_names=external-secrets bound_service_account_namespaces=toolbox policies=demo,rds_service ttl=200h

# exit out of container
exit

# read configured kubernetes auth method for verification
vault read auth/kubernetes/config

# read configured External Secret Operator(ESO) authenticate Role for verification
vault read auth/kubernetes/role/eso-role
```
## Installing and Configuring the External Secrets Operator
### SecretStore  
The SecretStore resource is to separate concerns of authentication/access and the actual Secret and configuration needed for workloads.
### ExternalSecret
The ExternalSecret specifies what to fetch, the SecretStore specifies how to access. This resource is namespaced.
### ClusterSecretStore
The ClusterSecretStore is a cluster scoped SecretStore that can be referenced by all ExternalSecrets from all namespaces whereas SecretStore is namespaced. Use it to offer a central gateway to your secret backend.

```text
kubens toolbox
helm repo add external-secrets https://charts.external-secrets.io
helm repo update external-secrets
helm search repo external-secrets
```
The output looks similar to the following:

```text
NAME                                    CHART VERSION   APP VERSION     DESCRIPTION                              
external-secrets/external-secrets       0.9.9           v0.9.9          External secret management for Kubernetes
```
Next, install the stack using Helm. The following command installs version 0.9.9 of external-secrets/external-secrets in your cluster, and also creates the external-secrets namespace, if it doesn't exist (it also installs CRDs):

```text
HELM_CHART_VERSION="0.5.9"

helm install external-secrets external-secrets/external-secrets --version "${HELM_CHART_VERSION}" \
  --namespace=toolbox \
  --create-namespace \
  --set installCRDs=true
```
Finally, check Helm release status:
```text
helm ls -n toolbox
```
The output looks similar to (STATUS column should display 'deployed'):

```text
NAME                    NAMESPACE               REVISION        UPDATED                                 STATUS          CHART                   APP VERSION
external-secrets        external-secrets        1               2022-09-10 10:33:50.324582 +0300 EEST   deployed        external-secrets-0.9.9  v0.9.9    
```
Next, inspect all the Kubernetes resources created for External Secrets:

```text
kubectl get all -n toolbox
```
The output looks similar to:
```text
NAME                                                    READY   STATUS    RESTARTS   AGE
pod/external-secrets-66457766c4-95mvm                   1/1     Running   0          48s
pod/external-secrets-cert-controller-6bd49df95b-8bw6x   1/1     Running   0          48s
pod/external-secrets-webhook-579c46bf-g4z6p             1/1     Running   0          48s
```
The ClusterSecretStore is a cluster scoped SecretStore that can be referenced by all ExternalSecrets from all namespaces whereas SecretStore is namespaced. Use it to offer a central gateway to your secret backend.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.toolbox:8200"
      path: "kv-v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "eso-role"
```
Create the ClusterSecretStore resource:
```text
kubectl apply -f ./infra/eso/cluster-secret-store.yaml
```
This command applies the ClusterSecretStore CRD to your cluster and creates the object. You can see the object by running the following command, which will show you all of the information about the object inside of Kubernetes:
```text
kubectl get ClusterSecretStore vault-backend
```
You should see something similar to:
```text
NAME            AGE   STATUS   READY
vault-backend   97s   Valid    True
```
## ExternalSecret
The ExternalSecret resource tells ESO to fetch a specific secret from a specific SecretStore and where to put the information.

ExternalSecret configuration for postgres service below:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: vault-rds-secret
spec:
  refreshInterval: "15s"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: rds-secret
  data:
    - secretKey: rds.host
      remoteRef:
        key: rds_service
        property: host

    - secretKey: rds.name
      remoteRef:
        key: rds_service
        property: name

    - secretKey: rds.password
      remoteRef:
        key: rds_service
        property: password

    - secretKey: rds.username
      remoteRef:
        key: rds_service
        property: username
```
ExternalSecret configuration for demo greeting message below:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: vault-demo-external-secret
spec:
  refreshInterval: "15s"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: demo-secret
  data:
    - secretKey: greeting.message
      remoteRef:
        key: demo
        property: message
```
Create the ExternalSecret resource:
```text
kubectl apply -f ./infra/eso/rds-service-external-secret.yaml
kubectl apply -f ./infra/eso/demo-external-secret.yaml
```
This command applies the ExternalSecret CRD to your cluster and creates the object. You can see the object by running the following command, which will show you all of the information about the object inside of Kubernetes:
```text
kubectl get ExternalSecret
```
You should see something similar to:
```text
NAME                         STORE           REFRESH INTERVAL   STATUS         READY
vault-demo-external-secret   vault-backend   15s                SecretSynced   True
vault-rds-secret             vault-backend   15s                SecretSynced   True
```
If the previous output has a Sync Error under STATUS, nmake sure your SecretStore is set up correctly. You can view the actual error by running the following command:
```text
kubectl get ExternalSecret vault-rds-secret -o yaml
```

Kubernetes Secrets should be created by ExternalSecret. Following command which will show the secrets:
```text
kubectl get Secret
```
You should see something similar to:
```text
NAME                                     TYPE                 DATA   AGE
demo-secret                              Opaque               1      37m
external-secrets-webhook                 Opaque               4      5h51m
rds-secret                               Opaque               4      93m
```
### Creating ServiceAccount, Role and RoleBinding
Application to access secrets, configmap application need service account role and role binding. 

#### Service Account
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: k8-application-sa
```
#### Role
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: k8-application-role
rules:
  - apiGroups: ["", "extensions", "apps"]
    resources: ["configmaps", "pods", "services", "endpoints", "secrets"]
    verbs: ["get", "watch", "list"]
```
#### Role Binding
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: k8-application-rb
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: k8-application-role
subjects:
  - kind: ServiceAccount
    name: k8-application-sa
```
Create the ServiceAccount, Role, RoleBinding resource:
```text
kubectl apply -f ./infra/eso/rb.yaml
```
### Install Postgres into Kubernetes Cluster
```text
kubectl apply -f ./infra/deployment/rds-deployment.yaml
```

### Create application docker image
```text
mvn clean install
docker build --tag=innotigers/springboot-eso:latest --rm=true .
```
Push application docker image to minikube docker registry using following command:
```text
minikube image load innotigers/springboot-eso:latest
```
### Deploy the application
```text
kubectl apply -f ./infra/deployment/app-deployment.yaml
```
Verify the deployment using below command:
```text
kubectl get pods
```
You should see something similar to:
```text
NAME                                                READY   STATUS    RESTARTS       AGE
external-secrets-666dc6fb64-lcv28                   1/1     Running   0              6h18m
external-secrets-cert-controller-58d987dfc4-chlcs   1/1     Running   0              6h18m
external-secrets-webhook-6fdf8765cf-77q6m           1/1     Running   0              6h18m
postgres-7b7d4dd76d-6qlf7                           1/1     Running   3 (7h9m ago)   8d
springboot-eso-798cd9b578-2vsfc                     1/1     Running   0              64m
vault-0                                             1/1     Running   4 (7h9m ago)   9d
vault-agent-injector-b4f6679fc-72plg                1/1     Running   5 (7h9m ago)   9d
```
Get the logs using below command:
```text
kubectl logs springboot-eso-798cd9b578-2vsfc
```
### How deployment manifest can load secrets to environment variable
```yaml
envFrom:
- secretRef:
    name: rds-secret
- secretRef:
    name: demo-secret
```
verify application is up and running
```text
kubectl port-forward -n toolbox svc/springboot-eso-svc 8090:8080
```

## Reference
1. https://dev.to/luafanti/injecting-secrets-from-vault-into-helm-charts-with-argocd-49k
2. https://luafanti.medium.com/injecting-secrets-from-vault-into-helm-charts-with-argocd-43fc1df57e74#:~:text=Vault%20setup,inject%20later%20into%20Helm%20Charts.&text=Now%20we%20need%20to%20create,will%20authenticate%20ArgoCD%20in%20Vault.
3. https://piotrminkowski.com/2022/08/08/manage-secrets-on-kubernetes-with-argocd-and-vault/
4. https://github.com/luafanti/arogcd-vault-plugin-with-helm/tree/main
5. https://github.com/argoproj-labs/argocd-vault-plugin/issues/495
6. https://verifa.io/blog/comparing-methods-for-accessing-secrets-in-vault-from-kubernetes/index.html

## useful commands
```text
minikube start
minikube unpause 
minikube dashboard 

docker build --tag=springboot-argocd:latest --rm=true .
docker tag springboot-argocd:latest innotigers/springboot-argocd:latest
docker run -it --rm -p 8080:8080 -p 8081:8081 innotigers/springboot-argocd:latest

docker login docker.io
docker push innotigers/springboot-argocd:latest

minikube image rm image <imagename>:<version>  
minikube image load <imagename>:<version> --daemon
minikube image load innotigers/springboot-argocd:latest
minikube image rm image innotigers/springboot-argocd:latest
minikube image ls

kubectl get secrets/example-secret -o yaml
```
