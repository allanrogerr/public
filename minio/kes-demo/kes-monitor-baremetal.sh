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
export KES_API_KEY=kes:v1:ACAAnPhnNURDjmrcrnYBiopv8nTlyfbAVBqcaEedBnDJ
export KES_SERVER=https://10.76.176.33:9073

./kes key ls -k
if [ $? -eq 0 ]; 
then
  echo "KES is accessible"
else
  echo "KES is not accessible"
  exit
fi

#### Status
./kes status --api -k

#### Logs
./kes log -k &
