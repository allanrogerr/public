#!/bin/bash

#### kes-operator: ssh -p 20083 ubuntu@65.49.37.23 -o "ServerAliveInterval=5" -o "ServerAliveCountMax=100000" -o "StrictHostKeyChecking=off"
#### Persist sessions
loginctl enable-linger ubuntu
if [[ $? -eq 0 ]];
then
	echo "loginctl is enabled"
else
	echo "loginctl is not available"
	exit
fi

#### Install and verify k3s
sudo touch /dev/kmsg
curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" sh -s - --snapshotter=fuse-overlayfs
systemctl is-active --quiet k3s
if [[ $? -eq 0 ]];
then
	echo "k3s is available"
else
	echo "k3s is not available"
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
	echo "krew is available"
else
	echo "krew is not available"
	exit
fi
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

#### Install kubectl minio https://min.io/docs/minio/kubernetes/upstream/reference/kubectl-minio-plugin.html#installation
kubectl krew update
kubectl krew install minio
kubectl minio version
if [[ $? -eq 0 ]];
then
	echo "kubectl-minio is available"
else
	echo "kubectl-minio is not available"
	exit
fi

#### Deploy minio
kubectl delete namespace/minio-operator
kubectl minio init --console-tls
if [[ $? -eq 0 ]];
then
	echo "minio operator is available"
else
	echo "minio operator is not available"
	exit
fi

NODEPORT_HTTP=31090
NODEPORT_HTTPS=30043
#### Create a NodePort and access the operator
kubectl patch service -n minio-operator console -p '{"spec":{"ports":[{"name": "http","port": 9090,"protocol": "TCP","nodePort":'${NODEPORT_HTTP}'},{"name": "https","port": 9443,"protocol": "TCP","nodePort":'${NODEPORT_HTTPS}'}],"type": "NodePort"}}'
if [[ $? -eq 0 ]];
then
  echo "Service was minio-operator nodeported"
else
  echo "Service was not minio-operator nodeported"
  exit
fi
kubectl patch deployment -n minio-operator minio-operator -p '{"spec":{"replicas":1}}'
if [[ $? -eq 0 ]];
then
  echo "Deployment minio-operator was shrunken"
else
  echo "Deployment minio-operator was not shrunken"
  exit
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

#### Wait for TLS certs to be issues and pods to be restarted automatically
RETRY=120
echo "Waiting for TLS certs to be issues and pods to be restarted automatically (${RETRY}s timeout)"
for ((check=1;check<=${RETRY};check++))
do
	if [[ ${check}>=${RETRY} ]];
	then
		echo "Console TLS was not enabled"
		exit
	fi
	if kubectl -n minio-operator logs deployment/minio-operator | grep -q "Restarting Console pods"; 
	then
		echo "Console TLS was enabled"
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
echo "Take note of the following JWT to access the minio operator."
echo "----"
echo $SA_TOKEN
echo "----"
echo ""
echo ""
echo "Access the minio operator console from https://$(hostname).lab.min.dev:${NODEPORT_HTTPS}"
