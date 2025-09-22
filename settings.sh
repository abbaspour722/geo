#!/usr/bin/env bash
set -euo pipefail


export CF_Token="bW0TOAsY1ei5yI9rNCnpM6eYeDi562MNVIcr5cFF"

domain="$1"  
nsdomain="$2" 
uuid="$3"
paths="$4"

install_xray() {
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version 1.8.23
}

install_dependencies() {
  echo -e "Installing and configuring dependencies..."
  apt update
  apt install -y screen unzip socat curl ca-certificates
}

generate_certificate() {
  echo "Preparing /etc/ssl/xray ..."
  mkdir -p /etc/ssl/xray
  chown root:root /etc/ssl/xray
  chmod 700 /etc/ssl/xray

  echo "Installing acme.sh..."
  curl https://get.acme.sh | sh
  export PATH="$HOME/.acme.sh:$PATH"

  if [ -n "${CF_Token:-}" ]; then
    echo "Using CF_Token (recommended)."
    export CF_Token="$CF_Token"
  else
    if [ -z "${CF_Key:-}" ] || [ -z "${CF_Email:-}" ]; then
      echo "ERROR: Set CF_Token (recommended) OR CF_Key and CF_Email before running."
      exit 1
    fi
    export CF_Key="$CF_Key"
    export CF_Email="$CF_Email"
    echo "Using CF_Key + CF_Email (global API key)."
  fi

  echo "Issuing certificate for *.$domain via DNS (Cloudflare)..."
  ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" -d "*.$domain" --keylength ec-256

  echo "Installing certificate to /etc/ssl/xray/ and setting reload hook..."
  ~/.acme.sh/acme.sh --install-cert -d "$domain" \
    --key-file /etc/ssl/xray/key.pem \
    --fullchain-file /etc/ssl/xray/cert.pem \
    --reloadcmd "systemctl restart xray.service || true"

  chmod 600 /etc/ssl/xray/key.pem
  chmod 644 /etc/ssl/xray/cert.pem
  echo "Wildcard certificate installed."
}

configure_xray() {
  echo "Configuring xray..."
  mkdir -p /usr/local/share/xray
  cd /usr/local/share/xray || true
  rm -rf *
  wget -q http://src.mouss.net/data/geoip.dat || true
  wget -q http://src.mouss.net/data/geosite.dat || true
  cd ~
  systemctl stop xray.service || true
  rm -f /usr/local/etc/xray/config.json

  cat >/usr/local/etc/xray/config.json <<-EOF
{
  "inbounds": [
    {
      "port": 2096,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "",
            "email": "free-client"
          }
        ],
        "decryption": "none",
        "fallbacks": []
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$domain",
          "certificates": [
            {
              "certificateFile": "/etc/ssl/xray/cert.pem",
              "keyFile": "/etc/ssl/xray/key.pem"
            }
          ]
        },
        "wsSettings": {
          "path": "$paths",
          "headers": {}
        }
      },
      "tag": "inbound-2096",
      "sniffing": {
        "enabled": false,
        "destOverride": ["http", "tls", "quic", "fakedns"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      }
    ]
  },
  "log": {
    "access": "none",
    "error": "",
    "loglevel": "warning"
  }
}
EOF

  echo "Generating client URI..."
  cat >~/free.uri <<-EOF
vless://$uuid@$nsdomain:2096?encryption=none&security=tls&sni=$nsdomain&alpn=http%2F1.1&fp=chrome&type=ws&host=$nsdomain&path=$paths#free-with-proxy-config
EOF

  systemctl restart xray.service || true
  echo "Xray configured and restarted."
}

# --- main
ufw disable || true
install_dependencies
install_xray
generate_certificate
configure_xray

echo "Done. Wildcard cert ready. Check /etc/ssl/xray/ and systemctl status xray"
