"""
Minimal script to test the APMIX.AI model response. No Flask, no S3, no
Parameter Store required — just set the API key (and optionally model/base
url) and run it.

Usage:
    export APMIX_API_KEY="sk-..."
    python test_apmix.py "Some text to summarize"

If you'd rather pull the key from SSM Parameter Store like the real app
does, set APMIX_API_KEY_PARAM instead of APMIX_API_KEY.
"""
import os
import sys

import requests

APMIX_BASE_URL = os.environ.get("APMIX_BASE_URL", "https://api.apmix.ai")
APMIX_MODEL = os.environ.get("APMIX_MODEL", "claude-sonnet-4-6-free")
APMIX_ANTHROPIC_VERSION = os.environ.get("APMIX_ANTHROPIC_VERSION", "2023-06-01")

API_KEY = "apx_live_2jDZFnHsRAr1KC7IZkaOkB5rJc9Uqjg0rkphRxmJ"
API_KEY_PARAM = os.environ.get("APMIX_API_KEY_PARAM")

if not API_KEY and API_KEY_PARAM:
    import boto3
    ssm = boto3.client("ssm", region_name=os.environ.get("AWS_REGION", "us-east-1"))
    API_KEY = ssm.get_parameter(Name=API_KEY_PARAM, WithDecryption=True)["Parameter"]["Value"]

if not API_KEY:
    sys.exit("Set APMIX_API_KEY (or APMIX_API_KEY_PARAM) before running this script.")

text = " ".join(sys.argv[1:]) or "The quick brown fox jumps over the lazy dog. This is a test document."

print(f"POST {APMIX_BASE_URL}/v1/messages  model={APMIX_MODEL}")

resp = requests.post(
    f"{APMIX_BASE_URL.rstrip('/')}/v1/messages",
    headers={
        "x-api-key": API_KEY,
        "anthropic-version": APMIX_ANTHROPIC_VERSION,
        "content-type": "application/json",
    },
    json={
        "model": APMIX_MODEL,
        "max_tokens": 256,
        "messages": [{"role": "user", "content": text}],
    },
    timeout=30,
)

print(f"status: {resp.status_code}")
print("raw body:")
print(resp.text)

if resp.ok:
    data = resp.json()
    blocks = data.get("content", [])
    summary = next((b.get("text") for b in blocks if isinstance(b, dict) and b.get("type") == "text"), None)
    print("\nparsed text:")
    print(summary or "(no text block found — check raw body above)")