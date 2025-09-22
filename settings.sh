#!/usr/bin/env bash
set -euo pipefail

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
  apt install -y screen unzip socat curl ufw
}

disable_firewall() {
  echo "Disabling UFW firewall (all ports open)..."
  ufw disable || true
}

configure_xray() {
  mkdir -p /etc/ssl/xray
  cd /usr/local/share/xray/
  rm -rf *
  wget -q http://src.mouss.net/data/geoip.dat
  wget -q http://src.mouss.net/data/geosite.dat
  cd ~
  systemctl stop xray.service
  rm -rf /usr/local/etc/xray/config.json

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

  echo "Generating client config..."
  cat >~/free.uri <<-EOF
vless://$uuid@$nsdomain:2096?encryption=none&security=tls&sni=$domain&alpn=http%2F1.1&fp=chrome&allowInsecure=1&type=ws&host=$domain&path=$paths#free-with-proxy-config
EOF

  systemctl restart xray.service
}

generate_certificate() {
  echo "Installing acme.sh and generating certificate..."
  curl https://get.acme.sh | sh
  ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256
  ~/.acme.sh/acme.sh --install-cert -d "$domain" \
    --key-file /etc/ssl/xray/key.pem \
    --fullchain-file /etc/ssl/xray/cert.pem
}

# --- main ---
install_dependencies
disable_firewall
install_xray
generate_certificate
configure_xray

echo "Done. Xray configured and firewall disabled (all ports open)."
