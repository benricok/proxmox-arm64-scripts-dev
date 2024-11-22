#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# Co-Author: benricok
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE

source /dev/stdin <<< "$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing APT Dependencies"
$STD apt-get install -y curl
$STD apt-get install -y sudo
$STD apt-get install -y mc
$STD apt-get install -y gpg
$STD apt-get install -y wget
$STD apt-get install -y openssh-server
$STD apt-get install -y \
  curl wget git build-essential \
  libncursesw5-dev libssl-dev libsqlite3-dev \
  tk-dev libgdbm-dev libc6-dev libbz2-dev pkg-config \
  ibffi-dev zlib1g-dev libxmlsec1 libxmlsec1-dev libxmlsec1-openssl \
  libmaxminddb0 sudo tzdata mc \
msg_ok "Installed APT Dependencies"

msg_info "Setting up Node.js Repository"
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" >/etc/apt/sources.list.d/nodesource.list
msg_ok "Set up Node.js Repository"

msg_info "Installing Node.js"
$STD apt-get update
$STD apt-get install -y nodejs
msg_ok "Installed Node.js"

msg_info "Installing Golang"
set +o pipefail
GOLANG=$(curl -s https://go.dev/dl/ | grep -o 'go[0-9.]*linux-arm64.tar.gz' | head -n 1)
wget -q https://golang.org/dl/$GOLANG
tar -xzf $GOLANG -C /usr/local
ln -s /usr/local/go/bin/go /usr/local/bin/go
set -o pipefail
msg_ok "Installed Golang"

msg_info "Installing yq"
wget https://github.com/mikefarah/yq/releases/download/v4.30.8/yq_linux_arm64 -O /usr/bin/yq
chmod +x /usr/bin/yq
msg_ok "Installed yq"

msg_info "Installing Python 3.11.1"
wget https://www.python.org/ftp/python/3.11.1/Python-3.11.1.tgz
tar xzf Python-3.11.1.tgz 
cd Python-3.11.1
./configure --enable-optimizations
sudo make altinstall # Install Python 3.11.1

cd $STARTING_DIR
rm -rf Python-3.11.1.tgz Python-3.11.1
msg_ok "Installed Python 3.11.1"

msg_info "Creating authentik user"
useradd --create-home --home-dir /opt/authentik --user-group --system --shell /bin/bash authentik
chown -R authentik:authentik /opt/authentik

cd /opt/authentik

msg_info "Installing pip"
curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
python3.11 get-pip.py
rm -rf get-pip.py
msg_ok "Installed pip"

msg_info "Installing virtualenv"
python3.11 -m pip install virtualenv
msg_ok "Installed virtualenv"

msg_info "Cloning authentik"
cd /opt/authentik
rm -rf ./src
git clone https://github.com/goauthentik/authentik.git src
cd /opt/authentik/src/
msg_ok "Cloned authentik"

msg_info "Activating python virtual env and installing python dependencies"
python3.11 -m virtualenv ./.venv
source .venv/bin/activate

# Install dependencies
pip install --no-cache-dir poetry
poetry export -f requirements.txt --output requirements.txt
poetry export -f requirements.txt --dev --output requirements-dev.txt

pip install --no-cache-dir -r requirements.txt -r requirements-dev.txt
msg_info "Activated python virtual env and installed python dependencies"


msg_info "Building web components"
cd /opt/authentik/src/website

npm i
npm run build-docs-only

cd /opt/authentik/src/web
npm i
npm run build
msg_ok "Built web components"

msg_info "Building authentik server"
cd /opt/authentik/src
# config search path patch -- /etc/authentik/config.yml is excluded from the search path by default in the Go code
sed -i "s/c.Setup(\".\/authentik\/lib\/default.yml\", \".\/local.env.yml\")/c.Setup(\"\/etc\/authentik\/config.yml\", \".\/authentik\/lib\/default.yml\", \".\/local.env.yml\")/" /opt/authentik/src/internal/config/config.go
/usr/local/go/bin/go build -o /opt/authentik/src/authentik-server  ./cmd/server/
msg_ok "Built authentik server"

msg_info "Creating service"
tee /etc/systemd/system/authentik-server.service > /dev/null << EOF
[Unit]
Description = Authentik Server (web/api/sso)

[Service]
ExecStart=/bin/bash -c 'source /opt/authentik/src/.venv/bin/activate && python -m lifecycle.migrate && /opt/authentik/src/authentik-server'
WorkingDirectory=/opt/authentik/src

User=authentik
Group=authentik

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

tee /etc/systemd/system/authentik-worker.service > /dev/null << EOF
[Unit]
Description = Authentik Worker (background tasks)

[Service]
ExecStart=/bin/bash -c 'source /opt/authentik/src/.venv/bin/activate && celery -A authentik.root.celery worker -Ofair --max-tasks-per-child=1 --autoscale 3,1 -E -B -s /tmp/celerybeat-schedule -Q authentik,authentik_scheduled,authentik_events'
WorkingDirectory=/opt/authentik/src

User=authentik
Group=authentik

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
msg_ok "Created service"

msg_info "Configuring authentik"
mkdir -p /etc/authentik
mkdir -p /opt/authentik/certs
mkdir -p /opt/authentik/blueprints

cp /opt/authentik/src/authentik/lib/default.yml /etc/authentik/config.yml
cp -r /opt/authentik/src/blueprints /opt/authentik/blueprints

yq -i ".secret_key = \"$(openssl rand -hex 32)\"" /etc/authentik/config.yml

yq -i ".error_reporting.enabled = false" /etc/authentik/config.yml
yq -i ".disable_update_check = true" /etc/authentik/config.yml
yq -i ".disable_startup_analytics = true" /etc/authentik/config.yml
yq -i ".avatars = \"none\"" /etc/authentik/config.yml

yq -i ".cert_discovery_dir = \"/opt/authentik/certs\"" /etc/authentik/config.yml
yq -i ".blueprints_dir = \"/opt/authentik/blueprints\"" /etc/authentik/config.yml
yq -i ".geoip = \"/opt/authentik/GeoLite2-City.mmdb\""  /etc/authentik/config.yml
msg_ok "Configured authentik"

msg_info "Enabling service"
systemctl enable -q --now peanut.service
msg_ok "Enabled service"
 
motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
