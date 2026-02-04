#!/usr/bin/env bash
set -euo pipefail

############################################
# Azure Policy Pre-Deployment Checklist
# Detects DENY policies that usually break
# automated deployments (Terraform / ARM)
############################################

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
OUTPUT_FILE="azure_policy_precheck_$(date +%Y%m%d_%H%M%S).txt"

echo "Azure Policy Precheck" | tee "$OUTPUT_FILE"
echo "Subscription: $SUBSCRIPTION_ID" | tee -a "$OUTPUT_FILE"
echo "----------------------------------------" | tee -a "$OUTPUT_FILE"

az account set --subscription "$SUBSCRIPTION_ID"

echo ""
echo "1️⃣ Policies with effect = DENY" | tee -a "$OUTPUT_FILE"
echo "----------------------------------------" | tee -a "$OUTPUT_FILE"

az policy assignment list \
  --query "[?policyDefinitionAction=='deny'].[name,scope,policyDefinitionId]" \
  -o table | tee -a "$OUTPUT_FILE"

echo ""
echo "2️⃣ DENY policies targeting common deployment blockers" | tee -a "$OUTPUT_FILE"
echo "----------------------------------------" | tee -a "$OUTPUT_FILE"

az policy assignment list \
  --query "[?policyDefinitionAction=='deny'] | [].{Name:name, Scope:scope, Policy:policyDefinitionId}" \
  -o json | jq -r '
  .[] | 
  select(
    (.Policy | test("Storage|Web|Authorization|ManagedIdentity|Network|Compute"; "i"))
  ) |
  "\(.Name) | \(.Scope) | \(.Policy)"
  ' | tee -a "$OUTPUT_FILE"

echo ""
echo "3️⃣ Allowed Locations / Allowed Resource Types" | tee -a "$OUTPUT_FILE"
echo "----------------------------------------" | tee -a "$OUTPUT_FILE"

az policy assignment list \
  --query "[?contains(policyDefinitionId,'allowed')].[name,scope,policyDefinitionId]" \
  -o table | tee -a "$OUTPUT_FILE"

echo ""
echo "4️⃣ Policies enforcing CMK / Network restrictions" | tee -a "$OUTPUT_FILE"
echo "----------------------------------------" | tee -a "$OUTPUT_FILE"

az policy assignment list -o json | jq -r '
.[] |
select(
  (.policyDefinitionId | test("key|cmk|private|network|public"; "i"))
) |
"\(.name) | \(.scope) | \(.policyDefinitionId)"
' | tee -a "$OUTPUT_FILE"

echo ""
echo "5️⃣ Management Group policies (informational)" | tee -a "$OUTPUT_FILE"
echo "----------------------------------------" | tee -a "$OUTPUT_FILE"

az policy assignment list \
  --scope "/providers/Microsoft.Management/managementGroups" \
  --query "[].{Name:name,Scope:scope,Policy:policyDefinitionId}" \
  -o table 2>/dev/null | tee -a "$OUTPUT_FILE" || echo "No MG access"

echo ""
echo "✅ Precheck finished"
echo "Review file: $OUTPUT_FILE"
