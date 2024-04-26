#!/bin/bash

#### kes-operator: ssh -p 20668 ubuntu@65.49.37.17 -o "ServerAliveInterval=5" -o "ServerAliveCountMax=100000" -o "StrictHostKeyChecking=off"
#### Persist sessions
loginctl enable-linger ubuntu
if [[ $? -eq 0 ]];
then
  echo "loginctl is enabled" >&2
else
  echo "loginctl is not available" >&2
  exit 255
fi

#### Install kubectl
sudo touch /dev/kmsg
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
curl -LO "https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256" && \
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check && \
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
kubectl version --client && \
kubectl version --client --output=yaml


#### Install kind
[ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
kind version


#### Install docker
sudo apt-get update && \
sudo apt-get -y install build-essential podman
sudo ln -s /usr/bin/podman /usr/bin/docker
docker version


#### Install go
cd $HOME && mkdir go && cd go && wget https://go.dev/dl/go1.21.9.linux-amd64.tar.gz && sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.21.9.linux-amd64.tar.gz
cat <<EOF >> $HOME/.profile 
export PATH=$PATH:/usr/local/go/bin:~/go/bin
EOF
cat $HOME/.profile 
source $HOME/.profile
go version


#### Deploy minio operator
kubectl delete namespace/minio-operator
rm -rf ~/github/operator && mkdir -p ~/github/operator && cd ~/github && git clone https://github.com/minio/operator.git && cd operator
TAG=localhost/minio/operator:noop
GITHUB_WORKSPACE=operator
CI="true"
SCRIPT_DIR=testing

make binary
(cd "${SCRIPT_DIR}/.." && docker build -t $TAG .)
cat << EOF > kind-config.yaml
# four node (two workers) cluster config
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
    - containerPort: 30043
      hostPort: 30043
      listenAddress: "0.0.0.0"
      protocol: TCP
  - role: worker
    extraPortMappings:
    - containerPort: 30044
      hostPort: 30044
      listenAddress: "0.0.0.0"
      protocol: TCP
  - role: worker
    extraPortMappings:
    - containerPort: 30045
      hostPort: 30045
      listenAddress: "0.0.0.0"
      protocol: TCP
  - role: worker
    extraPortMappings:
    - containerPort: 30046
      hostPort: 30046
      listenAddress: "0.0.0.0"
      protocol: TCP
  - role: worker
    extraPortMappings:
    - containerPort: 30047
      hostPort: 30047
      listenAddress: "0.0.0.0"
      protocol: TCP
EOF
kind delete cluster && kind create cluster --config kind-config.yaml
kind load docker-image $TAG
kubectl apply -k "${SCRIPT_DIR}/../resources"
#kubectl -n minio-operator set image deployment/minio-operator minio-operator="$TAG"
#kubectl -n minio-operator set image deployment/console console="$TAG"
#kubectl set env -n minio-operator deployment/minio-operator MINIO_CI_CD=on MINIO_CONSOLE_TLS_ENABLE=on
kubectl patch deployment -n minio-operator minio-operator -p '{"spec":{"replicas":1, "template":{"spec":{"containers":[{"name": "minio-operator", "env": [{"name": "MINIO_CI_CD", "value": "on"}, {"name": "MINIO_CONSOLE_TLS_ENABLE", "value": "on"}, {"name": "OPERATOR_STS_ENABLED", "value": "off"}], "image": "'$TAG'","resources":{"requests":{"ephemeral-storage": "0Mi"}}}]}}}}'
kubectl patch deployment -n minio-operator console -p '{"spec":{"replicas":1,"template":{"spec":{"containers":[{"name": "console","image":"'$TAG'"}]}}}}'

NODEPORT_HTTP=31090
NODEPORT_HTTPS=30043
#### Create a NodePort and access the operator
kubectl patch service -n minio-operator console -p '{"spec":{"ports":[{"name": "http","port": 9090,"protocol": "TCP","nodePort":'${NODEPORT_HTTP}'},{"name": "https","port": 9443,"protocol": "TCP","nodePort":'${NODEPORT_HTTPS}'}],"type": "NodePort"}}'
if [[ $? -eq 0 ]];
then
  echo "Service was minio-operator nodeported" >&2
else
  echo "Service was not minio-operator nodeported" >&2
  exit 255
fi


echo "Waiting for operator deployment to come online (30s timeout)"
kubectl wait --namespace minio-operator \
  --for=condition=Available deployment \
  --field-selector metadata.name=minio-operator \
  --timeout=30s

echo "Waiting for console deployment to come online (30s timeout)"
kubectl wait --namespace minio-operator \
  --for=condition=Available deployment \
  --field-selector metadata.name=console \
  --timeout=30s

#### Wait for TLS certs to be issued and pods to be restarted automatically
RETRY=120
echo "Waiting for TLS certs to be issues and pods to be restarted automatically (${RETRY}s timeout)"
for ((check=1;check<=${RETRY};check++))
do
  if [[ ${check}>=${RETRY} ]];
  then
    echo "Console TLS was not enabled" >&2
    exit 255
  fi
  if kubectl -n minio-operator logs deployment/minio-operator | grep -q "Restarting Console pods"; 
  then
    echo "Console TLS was enabled" >&2
    break
  else
    echo -n "."
    sleep 1
  fi
done

#### Get jwt
SA_TOKEN=$(kubectl -n minio-operator get secret console-sa-secret -o jsonpath="{.data.token}" | base64 --decode)
echo ""
echo ""
echo "Take note of the following JWT to access the minio operator." >&2
echo "----"
echo $SA_TOKEN >&2
echo "----"
echo ""
echo ""
echo "Access the minio operator console from https://$(hostname).minio.training:${NODEPORT_HTTPS}" >&2
echo "" >&2







#### Tenant
### Vault setup
#### Create vault pod
VAULT_PORT=8200
API_PORT=9000
for pid in $(sudo lsof -i :$VAULT_PORT -t)
do
  sudo kill "${pid}"
  echo "Killed port forward ${pid}" >&2
done
for pid in $(sudo lsof -i :$API_PORT -t)
do
  sudo kill "${pid}"
  echo "Killed port forward ${pid}" >&2
done

cd ~
VAULT_POD=$(kubectl -n default get pods -o json | jq '.items[] | select( .metadata.labels.app == "vault")' | jq -r '.metadata.name')
if [[ (! -z "${VAULT_POD}") ]];
then
  kubectl --namespace default delete deployment/vault
  echo "Waiting for previous vault pod ${VAULT_POD} to be removed"
  kubectl --namespace default wait --for=delete pod/$VAULT_POD --timeout=30s
fi

kubectl --namespace default delete service/vault
echo "Waiting for previous vault services to be removed"
kubectl --namespace default wait --for=delete svc/vault --timeout=30s
kubectl apply -f ~/github/operator/examples/vault/deployment.yaml
if [[ $? -eq 0 ]];
then
	echo "Vault deployment was applied" >&2
else
	echo "Vault deployment was not applied" >&2
	exit 255
fi

echo "Waiting for vault pods to come online (30s timeout)"
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
echo "Waiting for vault to be initialized (${RETRY}s timeout)"
for ((check=1;check<=${RETRY};check++))
do
	VAULT_LOGS=$(kubectl logs -l app=vault | tr -s '\n' ' ')
	VAULT_ADDR=$(echo $VAULT_LOGS | sed -n "s/^.*\(export VAULT_ADDR\S*\)\s*.*$/\1/p" | sed -n "s/0\.0\.0\.0/127\.0\.0\.1/p")
	VAULT_ROOT_TOKEN=$(echo $VAULT_LOGS | sed -n "s/^.*Root Token\:\s*\(\S*\)\s*.*$/\1/p")
  echo "Vault Logs: $VAULT_LOGS" >&2
	if [[ (! -z "${VAULT_ADDR}") && ! -z "${VAULT_ROOT_TOKEN}" ]]; 
	then
		echo "Vault was initialized" >&2
		break
	else
	  echo -n "."
    sleep 1
	fi
done
if [[ (-z "${VAULT_ADDR}") || -z "${VAULT_ROOT_TOKEN}" ]]; 
then
	echo "Vault was not initialized" >&2
	exit 255
fi

#### Interact with vault pod
VAULT_POD=$(kubectl -n default get pods -o json | jq '.items[] | select( .metadata.labels.app == "vault")' | jq -r '.metadata.name')
echo "Current vault pod: ${VAULT_POD}" >&2
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
echo "Role Id: $VAULT_ROLE_ID" >&2
VAULT_SECRET_ID=$(kubectl --namespace=default exec -it ${VAULT_POD} --container vault -- /bin/sh -c "cat VAULT_SECRET_ID.var | tr -d '\n'")
echo "Secret Id: $VAULT_SECRET_ID" >&2
if [[ (! -z "${VAULT_ROLE_ID}") && ! -z "${VAULT_SECRET_ID}" ]]; 
then
  echo "Vault was configured" >&2
else
  echo "Vault was not configured" >&2
  exit 255
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
	echo "Kustomize was installed" >&2
else
	echo "Kustomize was not installed" >&2
	exit 255
fi
kubectl delete namespace/tenant-kms-encrypted
kustomize build ~/github/operator/examples/kustomization/tenant-kes-encryption | kubectl apply -f -
if [[ $? -eq 0 ]];
then
	echo "Kustomization was built" >&2
else
	echo "Kustomization was not built" >&2
	exit 255
fi

#### Tweak tenant size and storeclass/pvcs
SERVERS=4
kubectl patch tenant -n tenant-kms-encrypted myminio --type='merge' -p  '{"spec":{"pools":[{"name": "pool-0", "servers": '${SERVERS}', "volumesPerServer": 4, "volumeClaimTemplate": {"apiVersion": "v1", "metadata": {"name": "data"}, "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}, "storageClassName": "standard"}}}]}}'
kubectl patch tenant -n tenant-kms-encrypted myminio --type='merge' -p  '{"spec":{"env": [{"name": "MINIO_BROWSER_LOGIN_ANIMATION","value": "false"}, {"name": "MINIO_CI_CD", "value": "on"}] }}'
if [[ $? -eq 0 ]];
then
  echo "Tenant was resized" >&2
else
  echo "Tenant was not resized" >&2
  exit 255
fi

kubectl -n tenant-kms-encrypted delete pods -l app=minio
kubectl -n tenant-kms-encrypted delete statefulset/myminio-pool-0
kubectl -n tenant-kms-encrypted delete statefulset/myminio-kes

echo "Waiting for tenant to be initialized (240s timeout)"
kubectl wait --namespace tenant-kms-encrypted \
  --for=jsonpath='{.status.currentState}'=Initialized tenant \
  --field-selector metadata.name=myminio \
  --timeout=240s

echo "Waiting for statefulset to be initialized (240s timeout)"
kubectl wait --namespace tenant-kms-encrypted \
  --for=jsonpath='{.status.replicas}='${SERVERS} statefulset \
  --selector v1.min.io/tenant=myminio \
  --timeout=240s

echo "Waiting for tenant pods to come online (240s timeout)"
kubectl wait --namespace tenant-kms-encrypted \
  --for=condition=Ready pod \
  --selector v1.min.io/tenant=myminio \
  --timeout=240s

#### Wait minio to come online
RETRY=120
echo "Waiting for minio to come online (${RETRY}s timeout)"
for ((check=1;check<=${RETRY};check++))
do
  if [[ ${check}>=${RETRY} ]];
  then
    echo "minio was not started successfully" >&2
    exit 255
  fi
  if kubectl -n tenant-kms-encrypted logs pod/myminio-pool-0-0 -c minio | grep -q "All MinIO sub-systems initialized successfully"; 
  then
    echo "minio was started successfully" >&2
    break
  else
    echo -n "."
    sleep 1
  fi
done

NODEPORT_HTTP=31092
NODEPORT_HTTPS=30045
#### Create a NodePort and access the operator/tenant
kubectl patch service -n tenant-kms-encrypted myminio-console -p '{"spec":{"ports":[{"name": "http-console","port": 9090,"protocol": "TCP","nodePort":'${NODEPORT_HTTP}'},{"name": "https-console","port": 9443,"protocol": "TCP","nodePort":'${NODEPORT_HTTPS}'}],"type": "NodePort"}}'
if [[ $? -eq 0 ]];
then
  echo "Service was nodeported" >&2
else
  echo "Service was not nodeported" >&2
  exit 255
fi

#### Install mc and validate
mkdir -p ~/mc && cd ~/mc && rm -rf mc* && wget https://dl.min.io/client/mc/release/linux-amd64/mc &> /dev/null
chmod +x mc && cd ~

#### Add a validating port forward
RETRY=10
for ((check=1;check<=${RETRY};check++))
do
  kubectl port-forward svc/myminio-hl $API_PORT:$API_PORT -n tenant-kms-encrypted &> /dev/null &
  mc/mc alias set kes-demo https://127.0.0.1:$API_PORT minio minio123 --insecure &> /dev/null
  if [[ $? -eq 0 ]];
  then
    break
  fi
  for pid in $(sudo lsof -i :$API_PORT -t)
  do
    sudo kill "${pid}"
    echo -n "."
  done
  sleep 1
done

mc/mc admin kms key status kes-demo --insecure >&2
# kubectl --namespace tenant-kms-encrypted port-forward svc/myminio-console 9043:9443 --address 0.0.0.0
# kubectl --namespace tenant-kms-encrypted port-forward svc/myminio-hl 9001:9000 --address 0.0.0.0 & #  for MINIO_SERVER_URL
echo ""
echo ""
echo "Access the minio tenant console from https://$(hostname).minio.training:${NODEPORT_HTTPS} using minio/minio123" >&2
echo ""
echo ""

exit 0