#!/usr/bin/env bash
# Helper to deploy main.bicep. Secrets (the PostgreSQL administrator password and the Open WebUI secret key)
# are never stored in the repository or in files (they are passed to Bicep as environment variables).
# By default it runs what-if only. Add --apply to actually create resources.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 -s <subscription> [-g <resource-group>] [options]

  -s  Subscription ID or name (required)
  -g  Resource group name (default: rg-owui-paas; created if missing)
  -u  PostgreSQL administrator name (default: owuiadmin)
  -p  PostgreSQL administrator password (alphanumeric only; if omitted, Bicep derives it from uniqueString)
  --reset-config  Reset the settings stored in the DB to the environment variable values at startup (use once, then remove the flag and redeploy)
  --apply  Deploy for real after what-if
USAGE
  exit 1
}

SUB="" RG="rg-owui-paas" PG_USER="" PG_PASS="" RESET=0 APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SUB="$2"; shift 2 ;;
    -g) RG="$2"; shift 2 ;;
    -u) PG_USER="$2"; shift 2 ;;
    -p) PG_PASS="$2"; shift 2 ;;
    --reset-config) RESET=1; shift ;;
    --apply) APPLY=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$SUB" ]] || usage

cd "$(dirname "$0")"

# Pass the PostgreSQL administrator name and password with arguments (-u / -p) or environment variables.
# If the password is empty, main.bicep derives it from uniqueString (use alphanumeric characters only because it is embedded in a URL)
[[ -n "$PG_USER" ]] && export PG_ADMIN_LOGIN="$PG_USER"
[[ -n "$PG_PASS" ]] && export PG_ADMIN_PASSWORD="$PG_PASS"
export PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-}"
# Secret key for signing Open WebUI sessions. If it is not passed as an environment variable, it is generated on every run (changing it invalidates existing logins)
export WEBUI_SECRET_KEY="${WEBUI_SECRET_KEY:-$(openssl rand -hex 32)}"

[[ "$RESET" -eq 1 ]] && export RESET_CONFIG_ON_START=true
LOCATION=$(az bicep build-params -f main.bicepparam --stdout | jq -r '.parametersJson | fromjson | .parameters.location.value')
echo "subscription : $SUB"
echo "resource grp : $RG ($LOCATION)"
az group create -n "$RG" -l "$LOCATION" --subscription "$SUB" -o none

args=(-g "$RG" --subscription "$SUB" -p main.bicepparam)
az deployment group what-if "${args[@]}"

if [[ "$APPLY" -eq 1 ]]; then
  az deployment group create "${args[@]}" --query properties.outputs -o json
  echo "The PostgreSQL connection string can be read from the Container App secret database-url:"
  echo "  az containerapp secret show -g $RG -n ca-owui --secret-name database-url --subscription $SUB --query value -o tsv"
else
  echo "Ran what-if only. Add --apply to deploy."
fi
