#!/usr/bin/env python3
"""
WARP+ Key Generator
Automatically generates a single WARP+ license key via Cloudflare API
Integrated into Marzban Ultimate VPN Installer
"""

import sys
import random
import time

try:
    import httpx
    import requests
except ImportError:
    print("Error: Required modules not installed", file=sys.stderr)
    print("Install: pip3 install httpx requests", file=sys.stderr)
    sys.exit(1)


def get_base_keys():
    """Fetch base keys for key generation"""
    try:
        response = requests.get(
            "https://gitlab.com/Misaka-blog/warp-script/-/raw/main/files/24pbgen/base_keys",
            timeout=10
        )
        response.raise_for_status()
        keys_str = response.content.decode("UTF-8")
        keys = [k.strip() for k in keys_str.split(",") if k.strip()]
        return keys
    except Exception as e:
        # Fallback to hardcoded keys if fetch fails
        return [
            "Qi286N5r-v4R05pT1-3Hl8V24w",
            "mJ9t3X82-N7hB46s9-Dq5yP13f",
            "Yk147R6p-b2S98vT4-Mw3nH71x"
        ]


def generate_single_key():
    """Generate a single WARP+ key"""
    
    base_keys = get_base_keys()
    
    headers = {
        "CF-Client-Version": "a-6.11-2223",
        "Host": "api.cloudflareclient.com",
        "Connection": "Keep-Alive",
        "Accept-Encoding": "gzip",
        "User-Agent": "okhttp/3.12.1",
    }
    
    max_retries = 3
    retry_count = 0
    
    while retry_count < max_retries:
        try:
            with httpx.Client(
                base_url="https://api.cloudflareclient.com/v0a2223",
                headers=headers,
                timeout=30.0,
            ) as client:
                
                # Register first account
                r = client.post("/reg")
                r.raise_for_status()
                id1 = r.json()["id"]
                license = r.json()["account"]["license"]
                token1 = r.json()["token"]
                
                # Register second account (referrer)
                r = client.post("/reg")
                r.raise_for_status()
                id2 = r.json()["id"]
                token2 = r.json()["token"]
                
                headers_get1 = {"Authorization": f"Bearer {token1}"}
                headers_get2 = {"Authorization": f"Bearer {token2}"}
                headers_post = {
                    "Content-Type": "application/json; charset=UTF-8",
                    "Authorization": f"Bearer {token1}",
                }
                
                # Set referrer
                json_data = {"referrer": id2}
                client.patch(f"/reg/{id1}", headers=headers_post, json=json_data)
                
                # Delete second account
                client.delete(f"/reg/{id2}", headers=headers_get2)
                
                # Apply base key
                base_key = random.choice(base_keys)
                json_data = {"license": base_key}
                client.put(f"/reg/{id1}/account", headers=headers_post, json=json_data)
                
                # Restore original license
                json_data = {"license": license}
                client.put(f"/reg/{id1}/account", headers=headers_post, json=json_data)
                
                # Get final account info
                r = client.get(f"/reg/{id1}/account", headers=headers_get1)
                r.raise_for_status()
                
                account_type = r.json().get("account_type", "")
                referral_count = r.json().get("referral_count", 0)
                final_license = r.json()["license"]
                
                # Delete first account
                client.delete(f"/reg/{id1}", headers=headers_get1)
                
                # Success - output the key
                print(final_license)
                print(f"Account Type: {account_type}", file=sys.stderr)
                print(f"Data Count: {referral_count} GB(s)", file=sys.stderr)
                
                return final_license
                
        except httpx.HTTPStatusError as e:
            retry_count += 1
            print(f"HTTP error occurred (attempt {retry_count}/{max_retries}): {e}", file=sys.stderr)
            if retry_count < max_retries:
                time.sleep(5)
        except httpx.RequestError as e:
            retry_count += 1
            print(f"Request error occurred (attempt {retry_count}/{max_retries}): {e}", file=sys.stderr)
            if retry_count < max_retries:
                time.sleep(5)
        except Exception as e:
            retry_count += 1
            print(f"Unexpected error (attempt {retry_count}/{max_retries}): {e}", file=sys.stderr)
            if retry_count < max_retries:
                time.sleep(10)
    
    print("Failed to generate WARP+ key after all retries", file=sys.stderr)
    sys.exit(1)


def main():
    """Main entry point"""
    try:
        generate_single_key()
    except KeyboardInterrupt:
        print("\nCancelled by user", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"Fatal error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
