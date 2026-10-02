#!/usr/bin/env bash

# Mint a GitHub App installation token and export it as GITHUB_TOKEN.
#
# Usage: source get_gh_token.sh APP_ID INSTALLATION_ID KEY_PATH
#
# This public copy is the bootstrap: consumer builds curl it from master to get
# the token they need to clone the private macinv/python-ci, which carries its
# own copy (scripts/get_gh_token.sh) for mid-build refreshes. Keep the two in
# step on failure handling; don't remove this one, nothing else can bootstrap.
#
# It is sourced straight into callers' build shells, so it deliberately does
# not `set -euo pipefail` (that would change the caller's own failure
# behaviour) and handles every exit status explicitly instead. A failed mint
# exits non-zero, which fails the caller's step at the mint rather than at the
# next command that needed the token.

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

# Exchange JWT for Installation Token.
#
# Retried only on a curl failure or HTTP 5xx: 3 attempts, 2s then 4s apart.
# 4xx is deterministic (bad key, wrong installation, revoked app), so it fails
# at once rather than delaying a clear error.
#
# A failure prints everything that can tell its causes apart: the request,
# the JWT's iat/exp, GitHub's Date header against this runner's clock (an exp
# GitHub thinks is too far ahead is a clock-skew failure), and the request id
# and rate-limit headers. The response headers go to a temp file, removed
# before this script returns; no trap, since this file is sourced and would
# replace the caller's.
GH_TOKEN_URL="https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens"
GH_TOKEN_HEADERS=$(mktemp "${TMPDIR:-/tmp}/gh_token_headers.XXXXXX") || {
  echo "❌ Failed to fetch token: could not create a temp file in ${TMPDIR:-/tmp}"
  exit 1
}

# _gh_token_header NAME: that header from the last response, or empty.
_gh_token_header() {
  grep -i "^$1:" "$GH_TOKEN_HEADERS" 2>/dev/null | tail -1 | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d '\r'
}

# _gh_token_redact TEXT: TEXT with any "token" value masked.
_gh_token_redact() {
  printf '%s\n' "$1" | sed -E 's/("token"[[:space:]]*:[[:space:]]*")[^"]*"/\1<redacted>"/g'
}

# _gh_token_utc EPOCH: EPOCH as an ISO-8601 UTC time (GNU or BSD date).
_gh_token_utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$1"
}

# _gh_token_context: what a failed mint needs to be diagnosed, one item a line.
_gh_token_context() {
  local now gh_date gh_epoch skew header value
  now=$(date +%s)
  echo "   Request: POST $GH_TOKEN_URL (app $APP_ID)"
  echo "   JWT: iat=$IAT exp=$EXP (exp $((EXP - NOW))s after signing at $(_gh_token_utc "$NOW"))"
  gh_date=$(_gh_token_header date)
  if [[ $CURL_RC -ne 0 ]]; then
    echo "   Clocks: runner $(_gh_token_utc "$now"); no response from GitHub to compare against"
  elif [[ -z "$gh_date" ]]; then
    echo "   Clocks: runner $(_gh_token_utc "$now"); GitHub sent no Date header"
  else
    gh_epoch=$(date -u -d "$gh_date" +%s 2>/dev/null || date -u -j -f '%a, %d %b %Y %T GMT' "$gh_date" +%s 2>/dev/null)
    if [[ -n "$gh_epoch" ]]; then
      skew=$((now - gh_epoch))
      if [[ $skew -ge 0 ]]; then
        skew="runner clock is ${skew}s ahead of GitHub"
      else
        skew="runner clock is $((-skew))s behind GitHub"
      fi
    else
      skew="couldn't parse GitHub's Date"
    fi
    echo "   Clocks: runner $(_gh_token_utc "$now"), GitHub $gh_date ($skew)"
  fi
  for header in x-github-request-id x-ratelimit-limit x-ratelimit-remaining x-ratelimit-used x-ratelimit-reset retry-after; do
    value=$(_gh_token_header "$header")
    if [[ -n "$value" ]]; then
      echo "   $header: $value"
    fi
  done
}

for ATTEMPT in 1 2 3; do
  CURL_RC=0
  : >"$GH_TOKEN_HEADERS"
  RESPONSE=$(curl -sS -X POST \
    -w '\nHTTP_STATUS:%{http_code}' \
    -D "$GH_TOKEN_HEADERS" \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    "$GH_TOKEN_URL") || CURL_RC=$?

  if [[ "$RESPONSE" == *$'\n'HTTP_STATUS:* || "$RESPONSE" == HTTP_STATUS:* ]]; then
    HTTP_STATUS="${RESPONSE##*HTTP_STATUS:}"
    BODY="${RESPONSE%HTTP_STATUS:*}"
    BODY="${BODY%$'\n'}"
  else
    HTTP_STATUS=""
    BODY="$RESPONSE"
  fi

  if [[ $CURL_RC -ne 0 ]]; then
    FAILURE="curl exited with status $CURL_RC"
  elif [[ "$HTTP_STATUS" == 5* ]]; then
    FAILURE="HTTP $HTTP_STATUS"
  else
    break
  fi

  if [[ $ATTEMPT -lt 3 ]]; then
    DELAY=$((2 ** ATTEMPT))
    REQUEST_ID=$(_gh_token_header x-github-request-id)
    echo "⚠️  Token mint attempt $ATTEMPT/3 failed ($FAILURE${REQUEST_ID:+, request id $REQUEST_ID}); retrying in ${DELAY}s"
    if [[ -n "$BODY" ]]; then
      _gh_token_redact "$BODY" | sed 's/^/   /'
    fi
    sleep "$DELAY"
  fi
done

# Only a successful (2xx) response may supply the token: after a final curl
# failure or 5xx the body is kept for the diagnostic but never trusted.
TOKEN=""
EXPIRY=""
if [[ $CURL_RC -eq 0 && "$HTTP_STATUS" == 2* ]]; then
  TOKEN=$(printf '%s' "$BODY" | grep -o '"token": *"[^"]*' | cut -d'"' -f4)
  EXPIRY=$(printf '%s' "$BODY" | grep -o '"expires_at": *"[^"]*' | cut -d'"' -f4)
fi

if [[ -z "$TOKEN" ]]; then
  # The body is only printed here, and with any "token" value redacted: a failed
  # (e.g. 5xx) response is not trusted for its token, but mustn't leak one either.
  if [[ $CURL_RC -ne 0 ]]; then
    echo "❌ Failed to fetch token: curl exited with status $CURL_RC after $ATTEMPT attempt(s)"
  else
    echo "❌ Failed to fetch token: HTTP ${HTTP_STATUS:-<none>} after $ATTEMPT attempt(s)"
  fi
  if [[ -n "$BODY" ]]; then
    _gh_token_redact "$BODY"
  fi
  _gh_token_context
  rm -f "$GH_TOKEN_HEADERS"
  exit 1
fi
rm -f "$GH_TOKEN_HEADERS"

# Export token into the current shell, and so to the commands it runs.
export GITHUB_TOKEN="$TOKEN"

echo "✅ GITHUB_TOKEN has been set"
echo "   Expires at: $EXPIRY"
