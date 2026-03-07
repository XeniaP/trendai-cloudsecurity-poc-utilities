
REQUIRED_RPS=(
  "Microsoft.Web"
  "Microsoft.KeyVault"
  "Microsoft.Storage"
  "Microsoft.EventHub"
  "Microsoft.OperationalInsights"
  "Microsoft.Insights"
  "Microsoft.OperationsManagement"
)

check_resource_providers() {
  local sub="$1" outfile="$2"
  : > "$outfile"
  for rp in "${REQUIRED_RPS[@]}"; do
    local state
    state="$(az provider show --namespace "$rp" --subscription "$sub" --query "registrationState" -o tsv 2>/dev/null || echo "UNKNOWN")"
    printf "%s\t%s\n" "$rp" "$state" >> "$outfile"
  done
}



# Worker per subscription (runs in parallel)
worker_sub() {
  local SUB_ID="$1" SUB_NAME="$2"

  az account set --subscription "$SUB_ID" >/dev/null 2>&1 || true

  # Regions list for this subscription
  local regions_file="$OUTDIR/${SUB_ID}.regions.txt"
  get_regions_for_subscription "$SUB_ID" > "$regions_file"

  # Quota checks per region (sequential inside subscription to reduce throttling)
  while IFS= read -r loc; do
    [[ -z "${loc:-}" ]] && continue
    res="$(get_dynamic_quota_tsv "$SUB_ID" "$loc")"
    printf "%s\n" "$res" > "$OUTDIR/${SUB_ID}.${loc}.tsv"
  done < "$regions_file"

  # Provider registration states (once per sub)
  check_resource_providers "$SUB_ID" "$OUTDIR/${SUB_ID}.rps.tsv"

  # Mark done
  echo -e "$SUB_ID\t$SUB_NAME" >> "$results_file"
}