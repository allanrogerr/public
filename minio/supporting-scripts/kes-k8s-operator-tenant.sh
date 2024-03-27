#!/bin/bash

#### kes-operator: ssh -p 20083 ubuntu@65.49.37.23 -o "ServerAliveInterval=5" -o "ServerAliveCountMax=100000" -o "StrictHostKeyChecking=off"
#### Persist sessions
loginctl enable-linger ubuntu
if [[ $? -eq 0 ]];
then
	logger "loginctl is enabled"
else
	logger "loginctl is not available"
	exit
fi

#### Install and verify k3s
sudo touch /dev/kmsg
curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" sh -s - --snapshotter=fuse-overlayfs
systemctl is-active --quiet k3s
if [[ $? -eq 0 ]];
then
	logger "k3s is available"
else
	logger "k3s is not available"
	exit
fi

#### Install krew see https://krew.sigs.k8s.io/docs/user-guide/setup/install/ for macOS/Linux > Bash or ZSH shells
(
  set -x; cd "$(mktemp -d)" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  KREW="krew-${OS}_${ARCH}" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
  tar zxvf "${KREW}.tar.gz" &&
  ./"${KREW}" install krew
)
if [[ $? -eq 0 ]];
then
	logger "krew is available"
else
	logger "krew is not available"
	exit
fi
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

#### Install kubectl minio https://min.io/docs/minio/kubernetes/upstream/reference/kubectl-minio-plugin.html#installation
kubectl krew update
kubectl krew install minio
kubectl minio version
if [[ $? -eq 0 ]];
then
	logger "kubectl-minio is available"
else
	logger "kubectl-minio is not available"
	exit
fi

#### Deploy minio
kubectl delete namespace/minio-operator
kubectl minio init --console-tls
if [[ $? -eq 0 ]];
then
	logger "minio operator is available"
else
	logger "minio operator is not available"
	exit
fi

NODEPORT_HTTP=31090
NODEPORT_HTTPS=30043
#### Create a NodePort and access the operator
kubectl patch service -n minio-operator console -p '{"spec":{"ports":[{"name": "http","port": 9090,"protocol": "TCP","nodePort":'${NODEPORT_HTTP}'},{"name": "https","port": 9443,"protocol": "TCP","nodePort":'${NODEPORT_HTTPS}'}],"type": "NodePort"}}'
if [[ $? -eq 0 ]];
then
  logger "Service was minio-operator nodeported"
else
  logger "Service was not minio-operator nodeported"
  exit
fi
kubectl patch deployment -n minio-operator minio-operator -p '{"spec":{"replicas":1}}'
if [[ $? -eq 0 ]];
then
  logger "Deployment minio-operator was shrunken"
else
  logger "Deployment minio-operator was not shrunken"
  exit
fi

logger "Waiting for operator deployment to come online (30s timeout)"
kubectl wait --namespace minio-operator \
  --for=condition=Available deployment \
  --field-selector metadata.name=minio-operator \
  --timeout=30s

logger "Waiting for console deployment to come online (30s timeout)"
kubectl wait --namespace minio-operator \
  --for=condition=Available deployment \
  --field-selector metadata.name=console \
  --timeout=30s

#### Wait for TLS certs to be issues and pods to be restarted automatically
RETRY=120
logger "Waiting for TLS certs to be issues and pods to be restarted automatically (${RETRY}s timeout)"
for ((check=1;check<=${RETRY};check++))
do
	if [[ ${check}>=${RETRY} ]];
	then
		logger "Console TLS was not enabled"
		exit
	fi
	if kubectl -n minio-operator logs deployment/minio-operator | grep -q "Restarting Console pods"; 
	then
		logger "Console TLS was enabled"
		break
	else
		logger -n "."
	  sleep 1
	fi
done

#### Get jwt
SA_TOKEN=$(kubectl -n minio-operator get secret console-sa-secret -o jsonpath="{.data.token}" | base64 --decode)
logger ""
logger ""
logger "Take note of the following JWT to access the minio operator."
logger "----"
logger $SA_TOKEN
logger "----"
logger ""
logger ""
logger "Access the minio operator console from https://$(hostname).lab.min.dev:${NODEPORT_HTTPS}"







#### Tenant
#### Persist sessions
loginctl enable-linger ubuntu
if [[ $? -eq 0 ]];
then
	logger "loginctl is enabled"
else
	logger "loginctl is not available"
	exit
fi

### Vault setup
#### Create vault pod
VAULT_PORT=8200
API_PORT=9000
for pid in $(sudo lsof -i :$VAULT_PORT -t)
do
  sudo kill "${pid}"
  logger "Killed port forward ${pid}"
done
for pid in $(sudo lsof -i :$API_PORT -t)
do
  sudo kill "${pid}"
  logger "Killed port forward ${pid}"
done

rm -rf ~/github/operator && mkdir -p ~/github/operator && cd ~/github && git clone https://github.com/minio/operator.git && cd ~
VAULT_POD=$(kubectl -n default get pods -o json | jq '.items[] | select( .metadata.labels.app == "vault")' | jq -r '.metadata.name')
if [[ (! -z "${VAULT_POD}") ]];
then
  kubectl --namespace default delete deployment/vault
  logger "Waiting for previous vault pod ${VAULT_POD} to be removed"
  kubectl --namespace default wait --for=delete pod/$VAULT_POD --timeout=30s
fi

kubectl --namespace default delete service/vault
logger "Waiting for previous vault services to be removed"
kubectl --namespace default wait --for=delete svc/vault --timeout=30s
kubectl apply -f ~/github/operator/examples/vault/deployment.yaml
if [[ $? -eq 0 ]];
then
	logger "Vault deployment was applied"
else
	logger "Vault deployment was not applied"
	exit
fi

logger "Waiting for vault pods to come online (30s timeout)"
kubectl wait --namespace default \
  --for=condition=Ready pod \
  --selector app=vault \
  --timeout=30s

#### Expose vault with a k8s port-forward
kubectl port-forward svc/vault $VAULT_PORT &
sleep 5
kubectl logs -l app=vault

#### Get general information on vault pod
RETRY=120
logger "Waiting for vault to be initialized (${RETRY}s timeout)"
for ((check=1;check<=${RETRY};check++))
do
	VAULT_LOGS=$(kubectl logs -l app=vault | tr -s '\n' ' ')
	VAULT_ADDR=$(echo $VAULT_LOGS | sed -n "s/^.*\(export VAULT_ADDR\S*\)\s*.*$/\1/p" | sed -n "s/0\.0\.0\.0/127\.0\.0\.1/p")
	VAULT_ROOT_TOKEN=$(echo $VAULT_LOGS | sed -n "s/^.*Root Token\:\s*\(\S*\)\s*.*$/\1/p")
	if [[ (! -z "${VAULT_ADDR}") && ! -z "${VAULT_ROOT_TOKEN}" ]]; 
	then
		logger "Vault was initialized"
		break
	else
	  logger -n "."
    sleep 1
	fi
done
if [[ (-z "${VAULT_ADDR}") || -z "${VAULT_ROOT_TOKEN}" ]]; 
then
	logger "Vault was not initialized"
	exit
fi

#### Interact with vault pod
VAULT_POD=$(kubectl -n default get pods -o json | jq '.items[] | select( .metadata.labels.app == "vault")' | jq -r '.metadata.name')
logger "Current vault pod: ${VAULT_POD}"
kubectl --namespace=default exec -it ${VAULT_POD} --container vault -- /bin/sh -c "${VAULT_ADDR}; \
export VAULT_TOKEN=${VAULT_ROOT_TOKEN}; \
export VAULT_FORMAT=\"json\"; \
vault auth disable approle; \
vault auth enable approle; \
vault secrets disable kv; \
vault secrets enable -version=1 kv; \
cat << EOF > kes-policy.hcl
path \"kv/*\" {
     capabilities = [ \"create\", \"read\", \"update\", \"patch\", \"delete\", \"list\" ]
}
EOF
\
vault policy write kes-policy kes-policy.hcl; \
vault write auth/approle/role/kes-role token_num_uses=0 secret_id_num_uses=0 period=5m policies=kes-policy; \

export VAULT_ROLE_ID=\$(vault read auth/approle/role/kes-role/role-id | grep -o '\"role_id\": \"[^\"]*' | grep -o '[^\"]*$'); \
echo \"\${VAULT_ROLE_ID}\" > VAULT_ROLE_ID.var \

export VAULT_SECRET_ID=\$(vault write -f auth/approle/role/kes-role/secret-id | grep -o '\"secret_id\": \"[^\"]*' | grep -o '[^\"]*$'); \
echo \"\${VAULT_SECRET_ID}\" > VAULT_SECRET_ID.var"
VAULT_ROLE_ID=$(kubectl --namespace=default exec -it ${VAULT_POD} --container vault -- /bin/sh -c "cat VAULT_ROLE_ID.var | tr -d '\n'")
logger "Role Id: $VAULT_ROLE_ID"
VAULT_SECRET_ID=$(kubectl --namespace=default exec -it ${VAULT_POD} --container vault -- /bin/sh -c "cat VAULT_SECRET_ID.var | tr -d '\n'")
logger "Secret Id: $VAULT_SECRET_ID"
if [[ (! -z "${VAULT_ROLE_ID}") && ! -z "${VAULT_SECRET_ID}" ]]; 
then
  logger "Vault was configured"
else
  logger "Vault was not configured"
  exit
fi

#### Customize kustomize
cat << EOF > ~/github/operator/examples/kustomization/tenant-kes-encryption/kes-configuration-secret-demo.yaml
apiVersion: v1
kind: Secret
metadata:
  name: kes-configuration
  namespace: tenant-kms-encrypted
type: Opaque
stringData:
  server-config.yaml: |-
    version: v1
    address: :7373
    admin:
      identity: \${MINIO_KES_IDENTITY}
    tls:
      key: /tmp/kes/server.key
      cert: /tmp/kes/server.crt
      proxy:
        identities: []
        header:
          cert: X-Tls-Client-Cert
    policy:
      my-policy:
        allow:
        - /v1/api
        - /v1/key/create/*
        - /v1/key/generate/*
        - /v1/key/decrypt/*
        - /v1/key/bulk/decrypt/*
        - /v1/key/list/*
        - /v1/status
        identities:
    cache:
      expiry:
        any: 5m0s
        unused: 20s
    log:
      error: on
      audit: off
    keystore:
      vault:
        version: "v1"
        endpoint: "http://vault.default.svc.cluster.local:8200"
        namespace: ""
        prefix: "my-minio"
        approle:
          id: "${VAULT_ROLE_ID}"
          secret: "${VAULT_SECRET_ID}"
          retry: 15s
        status:
          ping: 10s
EOF

cat << EOF > ~/github/operator/examples/kustomization/tenant-kes-encryption/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: tenant-kms-encrypted

resources:
  - ../base
  - kes-configuration-secret-demo.yaml

patchesStrategicMerge:
  - tenant.yaml
EOF

#### Install kustomize
sudo snap install kustomize
if [[ $? -eq 0 ]];
then
	logger "Kustomize was installed"
else
	logger "Kustomize was not installed"
	exit
fi
kubectl delete namespace/tenant-kms-encrypted
kustomize build ~/github/operator/examples/kustomization/tenant-kes-encryption | kubectl apply -f -
if [[ $? -eq 0 ]];
then
	logger "Kustomization was built"
else
	logger "Kustomization was not built"
	exit
fi

#### Tweak tenant size and storeclass/pvcs
SERVERS=4
kubectl patch tenant -n tenant-kms-encrypted myminio --type='merge' -p  '{"spec":{"pools":[{"name": "pool-0", "servers": '${SERVERS}', "volumesPerServer": 1, "volumeClaimTemplate": {"apiVersion": "v1", "metadata": {"name": "data"}, "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}, "storageClassName": "local-path"}}}]}}'
if [[ $? -eq 0 ]];
then
	logger "Tenant was resized"
else
	logger "Tenant was not resized"
	exit
fi

kubectl -n tenant-kms-encrypted delete pods -l app=minio
kubectl -n tenant-kms-encrypted delete statefulset/myminio-pool-0
kubectl -n tenant-kms-encrypted delete statefulset/myminio-kes

logger "Waiting for tenant to be initialized (240s timeout)"
kubectl wait --namespace tenant-kms-encrypted \
  --for=jsonpath='{.status.currentState}'=Initialized tenant \
  --field-selector metadata.name=myminio \
  --timeout=240s

logger "Waiting for statefulset to be initialized (240s timeout)"
kubectl wait --namespace tenant-kms-encrypted \
  --for=jsonpath='{.status.replicas}='${SERVERS} statefulset \
  --selector v1.min.io/tenant=myminio \
  --timeout=240s

logger "Waiting for tenant pods to come online (240s timeout)"
kubectl wait --namespace tenant-kms-encrypted \
  --for=condition=Ready pod \
  --selector v1.min.io/tenant=myminio \
  --timeout=240s

#### Wait minio to come online
RETRY=120
logger "Waiting for minio to come online (${RETRY}s timeout)"
for ((check=1;check<=${RETRY};check++))
do
  if [[ ${check}>=${RETRY} ]];
  then
    logger "minio was not started successfully"
    exit
  fi
  if kubectl -n tenant-kms-encrypted logs pod/myminio-pool-0-0 | grep -q "All MinIO sub-systems initialized successfully"; 
  then
    logger "minio was started successfully"
    break
  else
    logger -n "."
    sleep 1
  fi
done

NODEPORT_HTTP=31092
NODEPORT_HTTPS=30045
#### Create a NodePort and access the operator/tenant
kubectl patch service -n tenant-kms-encrypted myminio-console -p '{"spec":{"ports":[{"name": "http-console","port": 9090,"protocol": "TCP","nodePort":'${NODEPORT_HTTP}'},{"name": "https-console","port": 9443,"protocol": "TCP","nodePort":'${NODEPORT_HTTPS}'}],"type": "NodePort"}}'
if [[ $? -eq 0 ]];
then
  logger "Service was nodeported"
else
  logger "Service was not nodeported"
  exit
fi

#### Install mc and validate
mkdir -p ~/mc && cd ~/mc && rm -rf mc* && wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc && cd ~

#### Add a validating port forward
RETRY=10
for ((check=1;check<=${RETRY};check++))
do
  kubectl port-forward svc/myminio-hl $API_PORT:$API_PORT -n tenant-kms-encrypted &
  mc/mc alias set kes-demo https://127.0.0.1:$API_PORT minio minio123 --insecure
  if [[ $? -eq 0 ]];
  then
    break
  fi
  for pid in $(sudo lsof -i :$API_PORT -t)
  do
    sudo kill "${pid}"
    logger -n "."
  done
  sleep 1
done

mc/mc admin kms key status kes-demo --insecure

logger ""
logger ""
logger "Access the minio tenant console from https://$(hostname).lab.min.dev:${NODEPORT_HTTPS} using minio/minio123"
logger ""
logger ""