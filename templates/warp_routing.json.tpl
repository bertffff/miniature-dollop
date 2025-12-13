{
  "rules": [
    {
      "type": "field",
      "inboundTag": ["VLESS_REALITY_WARP"],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "geosite:openai",
        "domain:openai.com",
        "domain:ai.com",
        "domain:chat.openai.com",
        "domain:api.openai.com",
        "domain:auth0.openai.com",
        "domain:platform.openai.com",
        "domain:chatgpt.com"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:claude.ai",
        "domain:anthropic.com",
        "domain:api.anthropic.com"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:bard.google.com",
        "domain:gemini.google.com",
        "domain:generativelanguage.googleapis.com"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:perplexity.ai",
        "domain:poe.com",
        "domain:character.ai",
        "domain:beta.character.ai"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "geosite:netflix",
        "domain:netflix.com",
        "domain:netflix.net",
        "domain:nflxvideo.net",
        "domain:nflxso.net",
        "domain:nflxext.com",
        "domain:nflximg.net"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "geosite:disney",
        "domain:disneyplus.com",
        "domain:disney-plus.net",
        "domain:dssott.com",
        "domain:bamgrid.com",
        "domain:disney.com",
        "domain:disney.io"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:hulu.com",
        "domain:hulustream.com",
        "domain:huluim.com"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "geosite:spotify",
        "domain:spotify.com",
        "domain:scdn.co",
        "domain:spotifycdn.com",
        "domain:audio-ak-spotify-com.akamaized.net"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:hbomax.com",
        "domain:max.com",
        "domain:hbo.com"
      ],
      "outboundTag": "warp-out"
    },
    {
      "type": "field",
      "domain": [
        "domain:bing.com",
        "domain:copilot.microsoft.com"
      ],
      "outboundTag": "warp-out"
    }
  ]
}
