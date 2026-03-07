#!/usr/bin/env bash
set -euo pipefail

############################################
# Trend Vision One - Azure permissions precheck (all subscriptions + summary table)
#
# Subscription RBAC (OR logic):
#   PASS if ANY ONE exists at/inherited for subscription:
#     - Owner OR User Access Administrator OR Contributor
#   WARN if Contributor-only (RBAC automation may fail)
#   FAIL if none of the above exist
#
# Optional:
#   - Key Vault Secrets Officer (REQUIRE_KV_SECRETS_OFFICER=1)
#
# Entra roles (best-effort, informational, checked once):
#   - Application Administrator
#   - Privileged Role Administrator
#
# Usage:
#   chmod +x azure_v1_permissions_precheck_allsubs.sh
#   ./azure_v1_permissions_precheck_allsubs.sh
#
#   REQUIRE_KV_SECRETS_OFFICER=1 ./azure_v1_permissions_precheck_allsubs.sh
############################################

REQUIRE_KV_SECRETS_OFFICER="${REQUIRE_KV_SECRETS_OFFICER:-1}"
LOG_FILE="azure_v1_permissions_precheck_$(date +%Y%m%d_%H%M%S).log"

REQ_ENTRA_ROLES=("Application Administrator" "Privileged Role Administrator")

log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing command: $1"; exit 1; }
}

require_az_login() {
  if ! az account show >/dev/null 2>&1; then
    log "ERROR: Not logged in. Run: az login"
    exit 1
  fi
}

# Resolve signed-in objectId (user or service principal)
get_signed_in_object_id() {
  local user_type user_name
  user_type="$(az account show --query user.type -o tsv 2>/dev/null || true)"
  user_name="$(az account show --query user.name -o tsv 2>/dev/null || true)"

  log "Signed-in identity type: ${user_type:-unknown}"
  log "Signed-in identity name: ${user_name:-unknown}"

  if [[ "$user_type" == "user" ]]; then
    az ad signed-in-user show --query id -o tsv
  elif [[ "$user_type" == "servicePrincipal" ]]; then
    # In SP login, user.name is usually the appId
    az ad sp show --id "$user_name" --query id -o tsv
  else
    # Fallback attempt
    az ad signed-in-user show --query id -o tsv 2>/dev/null || true
  fi
}

# Check if a role assignment exists at subscription scope (including inherited)
has_role_assignment() {
  local assignee_oid="$1"
  local role_name="$2"
  local scope="$3"

  local count
  count="$(az role assignment list \
    --assignee-object-id "$assignee_oid" \
    --scope "$scope" \
    --include-inherited \
    --query "[?roleDefinitionName=='${role_name}'] | length(@)" -o tsv 2>/dev/null || echo "0")"

  [[ "$count" != "0" ]]
}

# Entra roles (best-effort) checked once; returns 3 values:
#   APP_ADMIN_STATUS, PRIV_ROLE_ADMIN_STATUS, ENTRA_QUERY_STATUS
# where statuses are: OK / MISSING / NA (not accessible)
entra_roles_once() {
  local json
  if ! json="$(az rest --method GET --url "https://graph.microsoft.com/v1.0/me/memberOf?\$select=displayName" 2>/dev/null)"; then
    echo "NA NA NA"
    return 0
  fi

  local app_admin="MISSING"
  local priv_role_admin="MISSING"

  if echo "$json" | grep -q "\"displayName\": \"Application Administrator\""; then
    app_admin="OK"
  fi
  if echo "$json" | grep -q "\"displayName\": \"Privileged Role Administrator\""; then
    priv_role_admin="OK"
  fi

  echo "$app_admin $priv_role_admin OK"
}

# Pretty table helpers
hr() {
  printf "%s\n" "----------------------------------------------------------------------------------------------------------------------------------------------------------------"
}

print_row() {
  # columns:
  # NAME | ID | SUB_STATUS | OWNER | UAA | CONTRIB | KV | NOTES | ENTRA_APP_ADMIN | ENTRA_PRIV_ROLE_ADMIN
  printf "%-28.28s | %-36.36s | %-6.6s | %-5.5s | %-3.3s | %-8.8s | %-4.4s | %-30.30s | %-8.8s | %-9.9s\n" \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
}


main() {
  require_cmd az
  require_az_login

  log "=== Trend Vision One | Azure permissions precheck (ALL subscriptions) ==="
  log "REQUIRE_KV_SECRETS_OFFICER=$REQUIRE_KV_SECRETS_OFFICER"
  log "Log file: $LOG_FILE"
  log ""

  # Resolve assignee object id once
  local assignee_oid
  assignee_oid="$(get_signed_in_object_id || true)"
  if [[ -z "${assignee_oid:-}" ]]; then
    log "ERROR: Could not resolve signed-in objectId."
    exit 1
  fi
  log "Signed-in objectId: $assignee_oid"
  log ""

  # Entra roles once (best-effort)
  local entra_app_admin entra_priv_admin entra_query_status
  read -r entra_app_admin entra_priv_admin entra_query_status < <(entra_roles_once)

  if [[ "$entra_query_status" == "NA" ]]; then
    log "WARN: Could not query Entra roles via Microsoft Graph (insufficient privileges or Graph blocked)."
    log "      Ask tenant admin to confirm Entra roles:"
    log "      - Application Administrator"
    log "      - Privileged Role Administrator"
  else
    log "Entra role check (informational): Application Admin=$entra_app_admin | Privileged Role Admin=$entra_priv_admin"
  fi
  log ""

  # Get all subscriptions (id + name)
  # Output TSV: id <tab> name
  mapfile -t subs < <(az account list --query "[].{id:id,name:name}" -o tsv)

  if [[ "${#subs[@]}" -eq 0 ]]; then
    log "ERROR: No subscriptions found."
    exit 1
  fi

  log "Subscriptions found: ${#subs[@]}"
  log ""

  # Arrays for summary
  declare -a R_NAME R_ID R_STATUS R_OWNER R_UAA R_CONTRIB R_KV R_NOTES
  local overall_fail=0

  for line in "${subs[@]}"; do
    # tsv may be: "<id>\t<name>"
    local sub_id sub_name
    sub_id="$(echo "$line" | awk -F'\t' '{print $1}')"
    sub_name="$(echo "$line" | awk -F'\t' '{print $2}')"
    [[ -z "${sub_id:-}" ]] && continue

    local scope="/subscriptions/${sub_id}"

    log "--------------------------------------------"
    log "Processing subscription: $sub_name ($sub_id)"
    az account set --subscription "$sub_id" >/dev/null

    local has_owner=0 has_uaa=0 has_contrib=0
    local kv_status="SKIP"
    local notes=""

    if has_role_assignment "$assignee_oid" "Owner" "$scope"; then
      has_owner=1
    fi
    if has_role_assignment "$assignee_oid" "User Access Administrator" "$scope"; then
      has_uaa=1
    fi
    if has_role_assignment "$assignee_oid" "Contributor" "$scope"; then
      has_contrib=1
    fi

    local sub_status="FAIL"
    if [[ "$has_owner" == "1" || "$has_uaa" == "1" || "$has_contrib" == "1" ]]; then
      sub_status="PASS"
      if [[ "$has_contrib" == "1" && "$has_owner" == "0" && "$has_uaa" == "0" ]]; then
        sub_status="WARN"
        notes="contributor-only"
      fi
    else
      overall_fail=1
      notes="missing required role"
    fi

    if [[ "$REQUIRE_KV_SECRETS_OFFICER" == "1" ]]; then
      if has_role_assignment "$assignee_oid" "Key Vault Secrets Officer" "$scope"; then
        kv_status="OK"
      else
        kv_status="WARN"
        if [[ -n "$notes" ]]; then
          notes="${notes}; kv-missing"
        else
          notes="kv-missing"
        fi
      fi
    fi

    # Store summary
    R_NAME+=("$sub_name")
    R_ID+=("$sub_id")
    R_STATUS+=("$sub_status")
    R_OWNER+=("$([[ "$has_owner" == "1" ]] && echo "YES" || echo "NO")")
    R_UAA+=("$([[ "$has_uaa" == "1" ]] && echo "YES" || echo "NO")")
    R_CONTRIB+=("$([[ "$has_contrib" == "1" ]] && echo "YES" || echo "NO")")
    R_KV+=("$kv_status")
    R_NOTES+=("$notes")

    log "Result: $sub_status | Owner=$has_owner UAA=$has_uaa Contributor=$has_contrib | KV=$kv_status | Notes=$notes"
  done

  # ===== Final summary table =====
  echo ""
  echo "==================== SUMMARY ===================="
  echo "Entra roles (informational, checked once):"
  echo "  Application Administrator:        $entra_app_admin"
  echo "  Privileged Role Administrator:    $entra_priv_admin"
  echo "  Entra role query status:          $entra_query_status"
  echo ""
  hr
  printf "%-28s | %-36s | %-6s | %-5s | %-3s | %-8s | %-4s | %-30s | %-8s | %-9s\n" \
    "Subscription" "SubscriptionId" "Status" "Owner" "UAA" "Contributor" "KV" "Notes" "EntraApp" "EntraPriv"
  hr

  local i
  for ((i=0; i<${#R_ID[@]}; i++)); do
    print_row \
      "${R_NAME[$i]}" \
      "${R_ID[$i]}" \
      "${R_STATUS[$i]}" \
      "${R_OWNER[$i]}" \
      "${R_UAA[$i]}" \
      "${R_CONTRIB[$i]}" \
      "${R_KV[$i]}" \
      "${R_NOTES[$i]:-}" \
      "$entra_app_admin" \
      "$entra_priv_admin"
  done
  hr
  echo ""
  echo "Log file: $LOG_FILE"

  if [[ "$overall_fail" == "1" ]]; then
    echo "Overall result: ❌ FAIL — one or more subscriptions do NOT have Owner/UAA/Contributor."
    exit 1
  else
    echo "Overall result: ✅ PASS — all subscriptions meet the OR-role requirement (some may be WARN: contributor-only)."
  fi
}

main "$@"
