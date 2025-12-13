{
  "tag": "warp-out",
  "protocol": "wireguard",
  "settings": {
    "secretKey": "${WARP_PRIVATE_KEY}",
    "address": [
      "${WARP_ADDRESS_V4}/32",
      "${WARP_ADDRESS_V6}/128"
    ],
    "peers": [
      {
        "publicKey": "${WARP_PUBLIC_KEY}",
        "allowedIPs": [
          "0.0.0.0/0",
          "::/0"
        ],
        "endpoint": "${WARP_ENDPOINT}"
      }
    ],
    "reserved": [0, 0, 0],
    "mtu": 1280,
    "workers": 2
  }
}
