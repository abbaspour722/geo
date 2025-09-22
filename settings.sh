#!/usr/bin/env bash
set -euo pipefail

domain="$1"
nsdomain="$2"
uuid="$3"
paths="$4"

install_xray() {
  echo "Installing Xray..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version 1.8.23
}

install_dependencies() {
  echo "Installing dependencies..."
  apt update
  apt install -y screen unzip socat curl ufw
}

disable_firewall() {
  echo "Disabling UFW firewall (all ports open)..."
  ufw disable || true
}

generate_certificate() {
  echo "Installing acme.sh and generating certificate..."
  curl https://get.acme.sh | sh
  export PATH="$HOME/.acme.sh:$PATH"

  echo "Issuing certificate for $domain via standalone mode..."
  ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256

  echo "Installing certificate to /etc/ssl/xray/..."
  mkdir -p /etc/ssl/xray
  ~/.acme.sh/acme.sh --install-cert -d "$domain" \
    --key-file /etc/ssl/xray/key.pem \
    --fullchain-file /etc/ssl/xray/cert.pem

  chmod 600 /etc/ssl/xray/key.pem
  chmod 644 /etc/ssl/xray/cert.pem
}

configure_xray() {
  echo "Configuring Xray..."
  mkdir -p /usr/local/share/xray
  cd /usr/local/share/xray
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
      "port": 443,
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
      "tag": "inbound-443",
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
vless://$uuid@$nsdomain:443?encryption=none&security=tls&sni=$domain&alpn=http%2F1.1&fp=chrome&type=ws&host=$nsdomain&path=$paths#free-with-proxy-config
EOF

  systemctl restart xray.service || true
}

# --- main ---
install_dependencies
disable_firewall
install_xray
generate_certificate
configure_xray

echo "Done. Xray installed with WS+TLS on port 443."
echo "Check /etc/ssl/xray/cert.pem and /usr/local/etc/xray/config.json"
echo "Client URI saved in ~/free.uri"
