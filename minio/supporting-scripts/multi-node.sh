#!/bin/bash

SCHEMA=$1 #https
HOST_PREFIX=$2 #minio-demo
HOST_DOMAIN=$3 #lab.min.dev
HOST_LIST=$4 #minio-demo4.lab.min.dev,minio-demo5.lab.min.dev,minio-demo6.lab.min.dev,minio-demo7.lab.min.dev
HOST_COUNT=$5 #4
HOST_COUNT_START=$6 #4

echo "Begin" > /tmp/minio.log

loginctl enable-linger $USER
echo "Killing minio" >> /tmp/minio.log
for pid in $(ps aux | grep "minio" | grep -v grep | grep -v $$ | awk '{print $2}')
do
      sudo kill "${pid}" 2>&1
      echo "Killed ${pid}"
done
sudo rm -rf /tmp/data*
sudo rm -rf ~/.minio/*

echo "Installing certs" >> /tmp/minio.log
rm -rf certgen-linux-amd64*
wget https://github.com/minio/certgen/releases/latest/download/certgen-linux-amd64
chmod +x certgen-linux-amd64
./certgen-linux-amd64 -host "127.0.0.1,${HOST_LIST}"
mkdir -p ~/.minio/certs/CAs
cp public.crt ~/.minio/certs
cp private.key ~/.minio/certs

# Add entry to hosts
if grep -q "127\.0\.0\.1 HOSTNAME" /etc/hosts;
then
      echo "/etc/hosts already setup" >> /tmp/minio.log
else
      echo "127.0.0.1 ${HOSTNAME}.${HOST_DOMAIN}" | sudo tee -a /etc/hosts
fi

# Install minio
echo "Installing minio" >> /tmp/minio.log
rm -rf minio*
wget https://dl.min.io/server/minio/release/linux-amd64/minio
chmod +x minio

# Run minio
echo "Running minio" >> /tmp/minio.log
echo "_MINIO_REVERSE_PROXY=1 MINIO_CI_CD=1 MINIO_BROWSER_REDIRECT_URL=\"${SCHEMA}://${HOST_PREFIX}${HOST_COUNT_START}.${HOST_DOMAIN}:9090\" MINIO_SERVER_URL=\"${SCHEMA}://${HOST_PREFIX}${HOST_COUNT_START}.${HOST_DOMAIN}:9000\" \
      ./minio server \
      ${SCHEMA}://${HOST_PREFIX}{${HOST_COUNT_START}...$((HOST_COUNT+HOST_COUNT_START-1))}.${HOST_DOMAIN}:9000/tmp/data{0...3} \
      --address :9000 --console-address :9090" >> /tmp/minio.log
# Cluster
_MINIO_REVERSE_PROXY=1 MINIO_CI_CD=1 MINIO_BROWSER_REDIRECT_URL="${SCHEMA}://${HOST_PREFIX}${HOST_COUNT_START}.${HOST_DOMAIN}:9090" MINIO_SERVER_URL="${SCHEMA}://${HOST_PREFIX}${HOST_COUNT_START}.${HOST_DOMAIN}:9000" \
nohup ./minio server \
${SCHEMA}://${HOST_PREFIX}{${HOST_COUNT_START}...$((HOST_COUNT+HOST_COUNT_START-1))}.${HOST_DOMAIN}:9000/tmp/data{0...3} \
--address :9000 --console-address :9090 --certs-dir ~/.minio/certs >> /tmp/minio.log 2>&1 &

echo "Done" >> /tmp/minio.log
