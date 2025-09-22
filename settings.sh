#!/usr/bin/env bash
set -euo pipefail


domain="$1"       
uuid="$2"         
wsPath="$3"      
xrayPort="${4:-443}"

install_dependencies() {
    echo "Installing dependencies..."
    apt update
    apt install -y curl wget unzip socat screen ufw
}

disable_firewall() {
    echo "Disabling UFW (all ports open)..."
    ufw disable || true
}

install_xray() {
    echo "Installing Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version 1.8.23
}

generate_certificate() {
    echo "Installing acme.sh and generating certificate..."
    curl https://get.acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
    
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256
    mkdir -p /etc/ssl/xray
    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file /etc/ssl/xray/key.pem \
        --fullchain-file /etc/ssl/xray/cert.pem \
        --reloadcmd "systemctl restart xray.service || true"

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
  "inbounds":[
    {
      "port":${xrayPort},
      "protocol":"vless",
      "settings":{
        "clients":[{"id":"${uuid}","flow":"","email":"free-client"}],
        "decryption":"none",
        "fallbacks":[]
      },
      "streamSettings":{
        "network":"ws",
        "security":"tls",
        "tlsSettings":{
          "serverName":"${domain}",
          "certificates":[{"certificateFile":"/etc/ssl/xray/cert.pem","keyFile":"/etc/ssl/xray/key.pem"}]
        },
        "wsSettings":{"path":"${wsPath}","headers":{}}
      },
      "tag":"inbound-${xrayPort}",
      "sniffing":{"enabled":false,"destOverride":["http","tls","quic","fakedns"]}
    }
  ],
  "outbounds":[{"protocol":"freedom","settings":{},"tag":"direct"},{"protocol":"blackhole","settings":{},"tag":"blocked"}],
  "routing":{"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"},{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"}]},
  "log":{"access":"none","error":"","loglevel":"warning"}
}
EOF

    systemctl restart xray.service || true


    cat >~/free.uri <<-EOF
vless://${uuid}@${domain}:${xrayPort}?encryption=none&security=tls&sni=${domain}&alpn=http%2F1.1&fp=chrome&allowInsecure=1&type=ws&host=${domain}&path=${wsPath}#Xray-WS-TLS
EOF

    echo "Client config generated: ~/free.uri"
}


install_dependencies
disable_firewall
install_xray
generate_certificate
configure_xray

echo "Done! Xray WS+TLS on Full Cloudflare SSL is ready."
