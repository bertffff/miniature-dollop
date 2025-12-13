{
  "log": {
    "loglevel": "${XRAY_LOG_LEVEL}",
    "access": "/var/lib/marzban/logs/access.log",
    "error": "/var/lib/marzban/logs/error.log"
  },
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService"
    ]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "api-inbound",
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "VLESS_REALITY_MAIN",
      "listen": "0.0.0.0",
      "port": ${XRAY_REALITY_PORT_1},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${XRAY_REALITY_SNI_1}:443",
          "xver": 0,
          "serverNames": [
            "${XRAY_REALITY_SNI_1}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [
            ${REALITY_SHORT_IDS_JSON}
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      }
    },
    {
      "tag": "VLESS_REALITY_STANDARD",
      "listen": "0.0.0.0",
      "port": ${XRAY_REALITY_PORT_2},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${XRAY_REALITY_SNI_2}:443",
          "xver": 0,
          "serverNames": [
            "${XRAY_REALITY_SNI_2}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [
            ${REALITY_SHORT_IDS_JSON}
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      }
    },
    {
      "tag": "VLESS_REALITY_WARP",
      "listen": "0.0.0.0",
      "port": ${XRAY_REALITY_PORT_3},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${XRAY_REALITY_SNI_3}:443",
          "xver": 0,
          "serverNames": [
            "${XRAY_REALITY_SNI_3}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [
            ${REALITY_SHORT_IDS_JSON}
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {}
    }
    ${WARP_OUTBOUND_JSON}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "api-inbound"
        ],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": [
          "geosite:category-ads-all"
        ],
        "outboundTag": "block"
      }
      ${WARP_ROUTING_RULES_JSON}
    ]
  }
}
