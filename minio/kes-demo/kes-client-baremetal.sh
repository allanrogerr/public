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

#### As a client, validate KES install
export KES_API_KEY=kes:v1:AHCduGH/k/G29jSBJwJwv2XZeHUuH1qJ91LB9ZfTUsfv
export KES_SERVER=https://10.76.176.33:9073
cat <<EOF > public.crt
-----BEGIN CERTIFICATE-----
MIIBNzCB6qADAgECAhAGNlfgXdv1sAI5OEHfghyMMAUGAytlcDAVMRMwEQYDVQQD
EwprZXMtc2VydmVyMB4XDTIzMTEyODE3MTYzMloXDTIzMTIyODE3MTYzMlowFTET
MBEGA1UEAxMKa2VzLXNlcnZlcjAqMAUGAytlcAMhALUHCMrX8GDStvI1nHmSQ632
rDWLVHzotY/WpOxfU1sro1AwTjAOBgNVHQ8BAf8EBAMCB4AwHQYDVR0lBBYwFAYI
KwYBBQUHAwIGCCsGAQUFBwMBMAwGA1UdEwEB/wQCMAAwDwYDVR0RBAgwBocECkyw
ITAFBgMrZXADQQCTeMsqefAR3Gh1aOWMletl1hJeOovoABYCnwW61NVAsWZHIvT7
GgagvIRqJeA88T4rCVz1Xc7D5MZTZIQJypYA
-----END CERTIFICATE-----
EOF

./kes key ls -k
if [ $? -eq 0 ]; 
then
  echo "KES is accessible"
else
  echo "KES is not accessible"
  exit
fi

#### Make certs
mkdir -p $HOME/.minio/certs
cd $HOME/.minio/certs
rm -rf certgen-linux-amd64*
wget https://github.com/minio/certgen/releases/latest/download/certgen-linux-amd64
chmod +x certgen-linux-amd64
./certgen-linux-amd64 -host "127.0.0.1"
if [ $? -eq 0 ]; 
then
  echo "certgen is installed"
else
  echo "certgen is not installed"
  exit
fi

#### Install and run minio
for pid in $(ps aux | grep "minio" | grep -v grep | grep -v $$ | awk '{print $2}')
do
  sudo kill "${pid}"
  echo "Killed ${pid}"
done

cd $HOME
rm -rf minio*
rm -rf /tmp/data
wget https://dl.min.io/server/minio/release/linux-amd64/minio
chmod +x minio
MINIO_KMS_KES_ENDPOINT=$KES_SERVER \
MINIO_KMS_KES_CAPATH=public.crt \
MINIO_KMS_KES_API_KEY=$KES_API_KEY \
MINIO_KMS_KES_KEY_NAME=minio-key \
CI=on \
./minio server /tmp/data --certs-dir $HOME/.minio/certs --address :9000 --console-address :9090 &

#### Install and run mc
rm -rf ~/mc && mkdir ~/mc && cd ~/mc && wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x ~/mc/mc
echo ""
echo ""
~/mc/mc alias set minio-client https://$(hostname).lab.min.dev:9000 minioadmin minioadmin
##### Attempt to check status
~/mc/mc admin kms key status minio-client --insecure
echo ""
echo ""
echo "Access minio console from https://$(hostname).lab.min.dev:9090"
echo ""
echo ""