#!/usr/bin/env bash

# Arguments: APP_ID INSTALLATION_ID KEY_PATH
APP_ID="${1:-}"
INSTALLATION_ID="${2:-}"
KEY_PATH="${3:-}"

if [[ -z "$APP_ID" || -z "$INSTALLATION_ID" || -z "$KEY_PATH" ]]; then
  echo "Usage: $0 APP_ID INSTALLATION_ID KEY_PATH"
  exit 1
fi

# Generate JWT
NOW=$(date +%s)
IAT=$((NOW - 60))    # issued-at: 60 seconds ago
EXP=$((NOW + 300))   # expires-at: 5 minutes later

b64() {
  openssl base64 -A | tr -d '=' | tr '/+' '_-'
}

HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | b64)
PAYLOAD=$(echo -n "{\"iat\":$IAT,\"exp\":$EXP,\"iss\":$APP_ID}" | b64)
SIGNATURE=$(echo -n "$HEADER.$PAYLOAD" \
  | openssl dgst -binary -sha256 -sign "$KEY_PATH" \
  | b64)

JWT="$HEADER.$PAYLOAD.$SIGNATURE"

# Exchange JWT for Installation Token
RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens")

TOKEN=$(echo "$RESPONSE" | grep -o '"token": *"[^"]*' | cut -d'"' -f4)
EXPIRY=$(echo "$RESPONSE" | grep -o '"expires_at": *"[^"]*' | cut -d'"' -f4)

if [[ -z "$TOKEN" ]]; then
  echo "❌ Failed to fetch token:"
  echo "$RESPONSE"
else
  # Export token into the current shell
  GITHUB_TOKEN="$TOKEN"

  echo "✅ GITHUB_TOKEN has been set"
  echo "   Expires at: $EXPIRY"
fi
