#!/usr/bin/env bash
set -euo pipefail

############################################
# Azure cleanup for Trend Micro / Vision One
# Targets names starting with: v1, trendmicro
#
# Resources:
#  - Role assignments (for matching roleDefinitionName OR matching principal displayName)
#  - Custom role definitions
#  - App registrations
#  - Service principals (orphans)
#  - Resource groups
#
# Usage:
#   DRY_RUN=1 ./azure_cleanup_v1_trendmicro.sh
#   DRY_RUN=0 ALL_SUBSCRIPTIONS=1 ./azure_cleanup_v1_trendmicro.sh
#   DRY_RUN=0 ALL_SUBSCRIPTIONS=1 ./azure_cleanup_v1_trendmicro.sh
#   DRY_RUN=0 SUBSCRIPTION_ID="xxxx-...." ./azure_cleanup_v1_trendmicro.sh
############################################

# ===== Config =====
PREFIX_1="v1"
PREFIX_2="trendmicro"
PREFIX_3="real-time-posture-monitoring"

DRY_RUN="${DRY_RUN:-0}"                 # 1 = only print actions, 0 = execute
ALL_SUBSCRIPTIONS="${ALL_SUBSCRIPTIONS:-1}"  # 1 = iterate all accessible subscriptions
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"       # optional: run only in this subscription
DELETE_RESOURCE_GROUPS="${DELETE_RESOURCE_GROUPS:-1}" # 1 = delete RGs, 0 = skip
NO_WAIT_RG_DELETE="${NO_WAIT_RG_DELETE:-1}"  # 1 = --no-wait, 0 = wait
LOG_FILE="${LOG_FILE:-azure_cleanup_$(date +%Y%m%d_%H%M%S).log}"

# ===== Helpers =====
log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE" >&2; }

run() {
  # run command or echo if DRY_RUN=1
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY-RUN] $*"
  else
    log "[RUN] $*"
    eval "$@"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "ERROR: missing command: $1"; exit 1; }
}

require_az_login() {
  if ! az account show >/dev/null 2>&1; then
    log "ERROR: Not logged in. Run: az login"
    exit 1
  fi
}

set_subscription() {
  local sub="$1"
  run "az account set --subscription \"$sub\""
}

# ===== Pre-flight =====
require_cmd az
require_az_login

log "=== Starting Azure cleanup ==="
log "DRY_RUN=$DRY_RUN | ALL_SUBSCRIPTIONS=$ALL_SUBSCRIPTIONS | SUBSCRIPTION_ID=${SUBSCRIPTION_ID:-<not set>}"
log "Prefixes: '$PREFIX_1*' and '$PREFIX_2*' and '$PREFIX_3*'"
log "Log file: $LOG_FILE"

# ===== Subscription selection =====
subs=()
if [[ -n "$SUBSCRIPTION_ID" ]]; then
  subs=("$SUBSCRIPTION_ID")
elif [[ "$ALL_SUBSCRIPTIONS" == "1" ]]; then
  mapfile -t subs < <(az account list --query "[].id" -o tsv)
else
  subs+=("$(az account show --query id -o tsv)")
fi

if [[ "${#subs[@]}" -eq 0 ]]; then
  log "ERROR: No subscriptions found."
  exit 1
fi

log "Subscriptions to process: ${#subs[@]}"

# ===== Functions =====

list_matching_app_ids() {
  az ad app list --query "[?starts_with(displayName,'$PREFIX_1') || starts_with(displayName,'$PREFIX_2') || starts_with(displayName,'$PREFIX_3')].appId" -o tsv
}

list_matching_sp_ids() {
  az ad sp list --query "[?starts_with(displayName,'$PREFIX_1') || starts_with(displayName,'$PREFIX_2') || starts_with(displayName,'$PREFIX_3')].id" -o tsv
}

list_matching_custom_role_ids() {
  az role definition list --custom-role-only true --query "[?starts_with(roleName,'$PREFIX_1') || starts_with(roleName,'$PREFIX_2') || starts_with(displayName,'$PREFIX_3')].name" -o tsv
}

list_matching_resource_groups() {
  az group list --query "[?starts_with(name,'$PREFIX_1') || starts_with(name,'$PREFIX_2') || starts_with(displayName,'$PREFIX_3')].name" -o tsv
}

delete_role_assignments_for_roles() {
  # Delete role assignments whose roleDefinitionName matches our prefixes
  local ids
  ids="$(az role assignment list --query "[?starts_with(roleDefinitionName,'$PREFIX_1') || starts_with(roleDefinitionName,'$PREFIX_2') || starts_with(displayName,'$PREFIX_3')].id" -o tsv || true)"

  if [[ -z "${ids// }" ]]; then
    log "No matching role assignments by roleDefinitionName found."
    return 0
  fi

  log "Deleting role assignments (matched by roleDefinitionName)..."
  while IFS= read -r rid; do
    [[ -z "$rid" ]] && continue
    run "az role assignment delete --ids \"$rid\""
  done <<< "$ids"
}

delete_role_assignments_for_principals() {
  # Delete role assignments for matching principals (SPs). This catches assignments
  # where role name isn't prefixed but the principal belongs to our apps.
  local sp_ids="$1"
  if [[ -z "${sp_ids// }" ]]; then
    log "No matching service principals found for principal-based assignment cleanup."
    return 0
  fi

  log "Deleting role assignments (for matching service principals)..."
  while IFS= read -r spid; do
    [[ -z "$spid" ]] && continue
    local a_ids
    a_ids="$(az role assignment list --assignee "$spid" --query "[].id" -o tsv || true)"
    if [[ -z "${a_ids// }" ]]; then
      continue
    fi
    while IFS= read -r aid; do
      [[ -z "$aid" ]] && continue
      run "az role assignment delete --ids \"$aid\""
    done <<< "$a_ids"
  done <<< "$sp_ids"
}

delete_custom_roles() {
  local role_ids="$1"
  if [[ -z "${role_ids// }" ]]; then
    log "No matching custom roles found."
    return 0
  fi

  log "Deleting custom role definitions..."
  while IFS= read -r roleId; do
    [[ -z "$roleId" ]] && continue
    run "az role definition delete --name \"$roleId\""
  done <<< "$role_ids"
}

delete_app_registrations() {
  local app_ids="$1"
  if [[ -z "${app_ids// }" ]]; then
    log "No matching app registrations found."
    return 0
  fi

  log "Deleting app registrations..."
  while IFS= read -r appId; do
    [[ -z "$appId" ]] && continue
    run "az ad app delete --id \"$appId\""
  done <<< "$app_ids"
}

delete_service_principals() {
  local sp_ids="$1"
  if [[ -z "${sp_ids// }" ]]; then
    log "No matching service principals found."
    return 0
  fi

  log "Deleting service principals..."
  while IFS= read -r spid; do
    [[ -z "$spid" ]] && continue
    run "az ad sp delete --id \"$spid\""
  done <<< "$sp_ids"
}

delete_resource_groups() {
  if [[ "$DELETE_RESOURCE_GROUPS" != "1" ]]; then
    log "Skipping Resource Group deletion (DELETE_RESOURCE_GROUPS=0)."
    return 0
  fi

  local rgs="$1"
  if [[ -z "${rgs// }" ]]; then
    log "No matching resource groups found."
    return 0
  fi

  log "Deleting resource groups..."
  while IFS= read -r rg; do
    [[ -z "$rg" ]] && continue
    if [[ "$NO_WAIT_RG_DELETE" == "1" ]]; then
      run "az group delete --name \"$rg\" --yes --no-wait"
    else
      run "az group delete --name \"$rg\" --yes"
    fi
  done <<< "$rgs"
}

# ===== Main loop per subscription =====
for sub in "${subs[@]}"; do
  log "--------------------------------------------"
  log "Processing subscription: $sub"
  set_subscription "$sub"

  # 1) Collect matching identities and roles (directory-level)
  matching_sp_ids="$(list_matching_sp_ids || true)"
  matching_app_ids="$(list_matching_app_ids || true)"
  matching_role_ids="$(list_matching_custom_role_ids || true)"
  matching_rgs="$(list_matching_resource_groups || true)"

  log "Found Service Principals: $(echo "$matching_sp_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  log "Found App Registrations:  $(echo "$matching_app_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  log "Found Custom Roles:       $(echo "$matching_role_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  log "Found Resource Groups:    $(echo "$matching_rgs" | sed '/^$/d' | wc -l | tr -d ' ')"

  # 2) Delete role assignments first
  delete_role_assignments_for_roles
  delete_role_assignments_for_principals "$matching_sp_ids"

  # 3) Delete custom roles
  delete_custom_roles "$matching_role_ids"

  # 4) Delete apps and SPs
  delete_app_registrations "$matching_app_ids"
  delete_service_principals "$matching_sp_ids"

  # 5) Delete resource groups last
  delete_resource_groups "$matching_rgs"

  log "Done subscription: $sub"
done

log "=== Cleanup finished ==="
log "Tip: Run again with DRY_RUN=1 to verify nothing remains."
