#!/bin/bash

#### Persist sessions
loginctl enable-linger ubuntu
if [ $? -eq 0 ];
then
	echo "loginctl is enabled"
else
	echo "loginctl is not available"
	exit
fi

#### Install and validate kes
curl -sSL --tlsv1.2 'https://github.com/minio/kes/releases/latest/download/kes-linux-amd64' -o ./kes
chmod +x ./kes
./kes --version 2>&1
if [ $? -eq 0 ]; 
then
  echo "KES is installed"
else
  echo "KES is not installed"
  exit
fi

#### Generate KES Server Private Key & Certificate. Obtain public.crt
export KES_SERVER_PORT=9073
export KES_SERVER_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [[ -z "${KES_SERVER_IP}" ]]; 
then
  echo "No IPv4 address was found"
  exit
fi
./kes identity new --key private.key --cert public.crt --ip "${KES_SERVER_IP}" kes-server --force
if [[ $? -eq 0 && (-s public.crt) ]]; 
then
  echo "KES server identity was generated."
else
  echo "KES server identity was not generated"
  exit
fi

#### Generate Client Credentials. Output response to file
KES_CLIENT=$(./kes identity new minio | tr -s '\n' ' ')
KES_CLIENT_API_KEY=$(echo $KES_CLIENT | sed -n "s/^.*Your API key\:\s*\(\S*\).*$/\1/p")
KES_CLIENT_IDENTITY=$(echo $KES_CLIENT | sed -n "s/^.*Your Identity\:\s*\(\S*\).*$/\1/p")
if [[ (! -z "${KES_CLIENT_API_KEY}") || ! -z "${KES_CLIENT_IDENTITY}" ]]; 
then
	echo "KES client identity was generated"
else
  echo "KES client identity was not generated"
  exit
fi

#### Generate Admin Credentials. Output response to file
KES_ADMIN=$(./kes identity new minio | tr -s '\n' ' ')
KES_ADMIN_API_KEY=$(echo $KES_ADMIN | sed -n "s/^.*Your API key\:\s*\(\S*\).*$/\1/p")
KES_ADMIN_IDENTITY=$(echo $KES_ADMIN | sed -n "s/^.*Your Identity\:\s*\(\S*\).*$/\1/p")
if [[ (! -z "${KES_ADMIN_API_KEY}") || ! -z "${KES_ADMIN_IDENTITY}" ]]; 
then
  echo "KES admin identity was generated"
else
  echo "KES admin identity was not generated"
  exit
fi

#### Configure KES Server
cat <<EOF > config.yml
address: 0.0.0.0:${KES_SERVER_PORT} # Listen on all network interfaces on port ${KES_SERVER_PORT}

admin:
  identity: ${KES_ADMIN_IDENTITY}  # We disable the admin identity since we don't need it in this guide 

policy:
  demo-client: 
    allow:
    - /v1/key/create/minio-key*
    - /v1/key/generate/minio-key*
    - /v1/key/decrypt/minio-key*
    - /v1/key/delete/minio-key*
    - /v1/key/list/*
    - /v1/status
    identities:
    - ${KES_CLIENT_IDENTITY}
tls:
  key: private.key    # The KES server TLS private key
  cert: public.crt    # The KES server TLS certificate

keystore:
  fs:
    path: ./keys
EOF
if [[ $? -eq 0 && ( -s config.yml) ]]; 
then
  echo "KES server config was generated."
else
  echo "KES server config was not generated"
  exit
fi

#### Start KES Server
for pid in $(ps aux | grep "kes" | grep -v grep | grep -v $$ | awk '{print $2}')
do
  sudo kill "${pid}"
  echo "Killed ${pid}"
done
./kes server --config config.yml > out.log &
if [[ $? -eq 0 ]]; 
then
  echo "KES server was started."
else
  echo "KES server was not started"
  exit
fi
echo ""
echo ""
echo "Copy the following public.crt to the client and monitor."
cat public.crt
echo ""
echo ""
echo "Use the following KES_SERVER and KES_API_KEY on the client."
echo "export KES_API_KEY=${KES_CLIENT_API_KEY}"
echo "export KES_SERVER=https://${KES_SERVER_IP}:${KES_SERVER_PORT}"
echo ""
echo ""
echo "Use the following KES_SERVER and KES_API_KEY on the monitor."
echo "export KES_API_KEY=${KES_ADMIN_API_KEY}"
echo "export KES_SERVER=https://${KES_SERVER_IP}:${KES_SERVER_PORT}"

