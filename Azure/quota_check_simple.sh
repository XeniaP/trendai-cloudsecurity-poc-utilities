#!/usr/bin/env bash
set -euo pipefail

############################################
# Azure QUOTA PRE-CHECK (Tabular Output)
#
# Output columns:
# Subscription | Region | Quota Y1 | Quota EP1
#
# Rules:
# - Y1 minimum: 50 per region
# - EP1 minimum: 1 service in MAIN REGION
#
# Defaults:
# - MAIN_REGION = eastus
# - EXCLUDE_FREE = true
############################################

EXCLUDE_FREE=true
MAIN_REGION="eastus"

MIN_Y1=50

log() { echo "[$(date +'%F %T')] $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }

# -------------------------------
# Get Y1 dynamic quota limit
# -------------------------------
get_y1_limit() {
  local sub="$1" region="$2"
  local versions=("2024-11-01" "2018-02-01" "2016-06-01")
  local v out

  for v in "${versions[@]}"; do
    out="$(az rest --method get \
      --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Web/locations/$region/usages?api-version=$v" \
      --query "value[?contains(name.value,'dynamic') && contains(name.value,'Linux')][0].limit" \
      -o tsv 2>/dev/null || true)"
    [[ "$out" =~ ^[0-9]+$ ]] && { echo "$out"; return 0; }
  done

  echo "0"
}

# -------------------------------
# EP1 availability (main region)
# -------------------------------
get_ep1_status() {
  local sub="$1" region="$2"

  az rest --method get \
    --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Web/locations/$region/capabilities?api-version=2022-09-01" \
    --query "value[?name=='ElasticPremium'].available" \
    -o tsv 2>/dev/null || echo "false"
}

# -------------------------------
# Regions with resources
# -------------------------------
get_used_regions() {
  local sub="$1"

  az graph query -q "
resources
| where subscriptionId == '${sub}'
| where isnotempty(location) and location !~ 'global'
| project location
| distinct location
" --first 1000 \
    --query "data[].location" -o tsv 2>/dev/null \
  | tr '\t' '\n' \
  | awk 'NF{print tolower($0)}' \
  | grep -E '^[a-z]' \
  | sort -u
}
# -------------------------------
# MAIN
# -------------------------------
main() {
  need az

  if ! az account show >/dev/null 2>&1; then
    echo "ERROR: run az login first" >&2
    exit 1
  fi

  TS="$(date +%Y%m%d_%H%M%S)"
  CSV_OUT="azure_quota_precheck_${TS}.csv"

  echo "Subscription,Region,Quota Y1,Quota EP1" > "$CSV_OUT"

  printf "%-30s | %-15s | %-10s | %-10s\n" "Subscription" "Region" "Quota Y1" "Quota EP1"
  printf "%-30s-+-%-15s-+-%-10s-+-%-10s\n" \
    "$(printf '%.0s-' {1..30})" \
    "$(printf '%.0s-' {1..15})" \
    "$(printf '%.0s-' {1..10})" \
    "$(printf '%.0s-' {1..10})"

  az account list --query "[?state=='Enabled'].[id,name,subscriptionPolicies.quotaId]" -o tsv |
  while read -r SUB_ID SUB_NAME QUOTA_ID; do

    qid="$(echo "$QUOTA_ID" | tr '[:upper:]' '[:lower:]')"
    if [[ "$EXCLUDE_FREE" == "true" ]] && [[ "$qid" == *"free"* || "$qid" == *"msdn"* ]]; then
      continue
    fi

    az account set --subscription "$SUB_ID" >/dev/null

    regions="$(get_used_regions "$SUB_ID")"
    regions="$(echo -e "$regions\n$MAIN_REGION" | sort -u)"

    for region in $regions; do
      y1="$(get_y1_limit "$SUB_ID" "$region")"

      if (( y1 < MIN_Y1 )); then
        y1_out="FAIL($y1)"
      else
        y1_out="$y1"
      fi

      if [[ "$region" == "$MAIN_REGION" ]]; then
        ep1_raw="$(get_ep1_status "$SUB_ID" "$region")"
        [[ "$ep1_raw" == "true" ]] && ep1_out="OK" || ep1_out="FAIL"
      else
        ep1_out="N/A"
      fi

      printf "%-30s | %-15s | %-10s | %-10s\n" \
        "$SUB_NAME" "$region" "$y1_out" "$ep1_out"

      echo "\"$SUB_NAME\",\"$region\",\"$y1_out\",\"$ep1_out\"" >> "$CSV_OUT"
    done
  done

  echo
  echo "CSV generated: $CSV_OUT"
}

main "$@"
