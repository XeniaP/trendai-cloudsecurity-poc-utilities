#!/usr/bin/env bash
# checkResourceProviders.sh
# Check required Azure Resource Providers for one or all accessible subscriptions.
# Usage:
#   ./checkResourceProviders.sh                   # all subscriptions
#   ./checkResourceProviders.sh -s <sub-id>       # single subscription
#   ./checkResourceProviders.sh --register        # auto-register missing providers
#   ./checkResourceProviders.sh -s <sub-id> --register

set -euo pipefail

# ── Required Resource Providers ────────────────────────────────────────────────
REQUIRED_RPS=(
  "Microsoft.Web"
  "Microsoft.KeyVault"
  "Microsoft.Storage"
  "Microsoft.EventHub"
  "Microsoft.OperationalInsights"
  "Microsoft.Insights"
  "Microsoft.OperationsManagement"
)

# ── Defaults ───────────────────────────────────────────────────────────────────
TARGET_SUB=""
AUTO_REGISTER=false
OUTDIR="$(pwd)/rp_check_results"
SUMMARY_CSV="$OUTDIR/summary.csv"

# ── Parse Arguments ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--subscription)
      TARGET_SUB="$2"
      shift 2
      ;;
    --register)
      AUTO_REGISTER=true
      shift
      ;;
    -h|--help)
      sed -n '3,7p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUTDIR"

# ── Helper: check (and optionally register) providers for one subscription ─────
check_resource_providers() {
  local sub_id="$1" sub_name="$2"
  local results=()

  for rp in "${REQUIRED_RPS[@]}"; do
    local state
    state="$(az provider show \
               --namespace "$rp" \
               --subscription "$sub_id" \
               --query "registrationState" \
               -o tsv 2>/dev/null || echo "UNKNOWN")"

    if [[ "$state" == "Registered" ]]; then
      results+=("$rp:Yes")
    else
      results+=("$rp:No ($state)")

      if [[ "$AUTO_REGISTER" == true ]]; then
        echo "  [INFO] Registering $rp in subscription $sub_name ($sub_id)..."
        if az provider register --namespace "$rp" --subscription "$sub_id" --wait >/dev/null 2>&1; then
          results[-1]="$rp:Registered (just registered)"
          echo "  [OK]   $rp registered successfully."
        else
          echo "  [WARN] Failed to register $rp — check permissions." >&2
        fi
      fi
    fi
  done

  # Return results as a single line: sub_id|sub_name|rp1:val|rp2:val|...
  local row="$sub_id|$sub_name"
  for r in "${results[@]}"; do
    row+="|$r"
  done
  echo "$row"
}

# ── Collect subscriptions ──────────────────────────────────────────────────────
if [[ -n "$TARGET_SUB" ]]; then
  SUB_LIST="$(az account show --subscription "$TARGET_SUB" \
               --query "[id, name]" -o tsv 2>/dev/null)"
  if [[ -z "$SUB_LIST" ]]; then
    echo "ERROR: Subscription '$TARGET_SUB' not found or not accessible." >&2
    exit 1
  fi
else
  SUB_LIST="$(az account list --query "[].{id:id, name:name}" -o tsv 2>/dev/null)"
  if [[ -z "$SUB_LIST" ]]; then
    echo "ERROR: No subscriptions found. Run 'az login' first." >&2
    exit 1
  fi
fi

# ── Run checks ─────────────────────────────────────────────────────────────────
declare -a ALL_ROWS=()

while IFS=$'\t' read -r sub_id sub_name; do
  [[ -z "${sub_id:-}" ]] && continue
  echo "Checking subscription: $sub_name ($sub_id)..."
  row="$(check_resource_providers "$sub_id" "$sub_name")"
  ALL_ROWS+=("$row")
done <<< "$SUB_LIST"

# ── Build & display summary table ─────────────────────────────────────────────
COL_W=28    # width for RP columns
SUB_W=36    # width for subscription name

print_separator() {
  local cols=$(( ${#REQUIRED_RPS[@]} ))
  printf '+%s+%s' "$(printf '%0.s-' $(seq 1 $((SUB_W+2))))" "$(printf '%0.s-' $(seq 1 $((SUB_W+2))))"
  for (( i=0; i<cols; i++ )); do
    printf '+%s' "$(printf '%0.s-' $(seq 1 $((COL_W+2))))"
  done
  printf '+\n'
}

print_header() {
  printf '| %-*s | %-*s' "$SUB_W" "Subscription ID" "$SUB_W" "Subscription Name"
  for rp in "${REQUIRED_RPS[@]}"; do
    printf ' | %-*s' "$COL_W" "${rp##*.}"   # short name after last dot
  done
  printf ' |\n'
}

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo " RESOURCE PROVIDER CHECK RESULTS"
if [[ "$AUTO_REGISTER" == true ]]; then
  echo " (--register enabled: missing providers were registered)"
fi
echo "════════════════════════════════════════════════════════════════════════"
echo ""

print_separator
print_header
print_separator

# Write CSV header
{
  printf 'Subscription ID,Subscription Name'
  for rp in "${REQUIRED_RPS[@]}"; do printf ',%s' "$rp"; done
  printf '\n'
} > "$SUMMARY_CSV"

for row in "${ALL_ROWS[@]}"; do
  IFS='|' read -ra parts <<< "$row"
  sub_id="${parts[0]}"
  sub_name="${parts[1]}"

  printf '| %-*s | %-*s' "$SUB_W" "$sub_id" "$SUB_W" "$sub_name"

  # CSV row start
  csv_row="\"$sub_id\",\"$sub_name\""

  for (( i=0; i<${#REQUIRED_RPS[@]}; i++ )); do
    val="${parts[$((i+2))]:-N/A}"
    display="${val#*:}"   # strip "RP:" prefix
    printf ' | %-*s' "$COL_W" "$display"
    csv_row+=",\"$display\""
  done

  printf ' |\n'
  echo "$csv_row" >> "$SUMMARY_CSV"
done

print_separator

# ── Register prompt (interactive, when --register not passed) ──────────────────
if [[ "$AUTO_REGISTER" == false ]]; then
  echo ""
  read -r -p "Do you want to register any MISSING providers now? [y/N]: " ANSWER
  if [[ "${ANSWER,,}" == "y" ]]; then
    AUTO_REGISTER=true
    echo ""
    for row in "${ALL_ROWS[@]}"; do
      IFS='|' read -ra parts <<< "$row"
      sub_id="${parts[0]}"
      sub_name="${parts[1]}"
      for (( i=0; i<${#REQUIRED_RPS[@]}; i++ )); do
        rp="${REQUIRED_RPS[$i]}"
        val="${parts[$((i+2))]:-}"
        status="${val#*:}"
        if [[ "$status" != "Yes" ]]; then
          read -r -p "  Register $rp in [$sub_name]? [y/N]: " REG_ANSWER
          if [[ "${REG_ANSWER,,}" == "y" ]]; then
            echo "  Registering $rp..."
            if az provider register --namespace "$rp" --subscription "$sub_id" --wait >/dev/null 2>&1; then
              echo "  [OK] $rp registered."
            else
              echo "  [WARN] Failed to register $rp." >&2
            fi
          fi
        fi
      done
    done
  fi
fi

echo ""
echo "Results saved to: $SUMMARY_CSV"
echo ""
