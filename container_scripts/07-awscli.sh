#!/usr/bin/env bash
# Cài đặt AWS CLI v2
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws

ln -sf /usr/local/bin/aws /usr/bin/aws
ln -sf /usr/local/bin/aws_completer /usr/bin/aws_completer

echo 'export PATH=$PATH:/usr/local/bin' >> /root/.bashrc
echo 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' >> /etc/environment

aws --version
echo "✅ awscli installed"
