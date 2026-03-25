import os
import json
import requests

account_id = os.environ.get("CF_ACCOUNT_ID")
api_token = os.environ.get("CF_TOKEN_MAIN")

url = f"https://api.cloudflare.com/client/v4/accounts/{account_id}/gateway/lists"
headers = {
    "Authorization": f"Bearer {api_token}",
    "Content-Type": "application/json"
}

print("Downloading advanced adblock lists...")

sources = [
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
]

domains = set()
for source in sources:
    print(f"Fetching from {source}...")
    try:
        resp = requests.get(source)
        if resp.status_code == 200:
            for line in resp.text.splitlines():
                line = line.split(chr(35))[0].strip()
                if line.startswith("0.0.0.0"):
                    parts = line.split()
                    if len(parts) >= 2:
                        domain = parts[1]
                        if domain not in ["0.0.0.0", "localhost"]:
                            domains.add(domain)
    except Exception as e:
        print(f"Error fetching {source}: {e}")

domains = list(domains)
print(f"Total unique domains extracted: {len(domains)}")

max_domains = 5000
domains = domains[:max_domains]

chunk_size = 1000
chunks = [domains[i:i + chunk_size] for i in range(0, len(domains), chunk_size)]
print(f"Divided into {len(chunks)} chunks.")

print("Checking existing lists on Cloudflare...")
resp = requests.get(url, headers=headers)

if resp.status_code != 200:
    print(f"Critical Error: Authentication failed with status {resp.status_code}")
    print(f"Response: {resp.text}")
    exit(1)

existing_lists = resp.json().get("result")
if existing_lists is None:
    existing_lists = []

prefix = "Auto-Adblock-Part-"
for lst in existing_lists:
    if lst.get("name") and lst["name"].startswith(prefix):
        print(f"Deleting old list: {lst['name']}")
        requests.delete(f"{url}/{lst['id']}", headers=headers)

for i, chunk in enumerate(chunks):
    list_name = f"{prefix}{i+1}"
    print(f"Pushing {list_name} ({len(chunk)} domains)...")
    payload = {
        "name": list_name,
        "type": "DOMAIN",
        "description": "Auto-updated via GitHub Actions",
        "items": [{"value": d} for d in chunk]
    }
    push_resp = requests.post(url, headers=headers, data=json.dumps(payload))
    if push_resp.status_code != 200:
        print(f"Failed to push {list_name}: {push_resp.text}")

print("Successfully updated advanced adblock lists!")
