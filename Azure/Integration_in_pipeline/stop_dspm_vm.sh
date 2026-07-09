#!/bin/bash
# stop_dspm_vms.sh
# Detiene todas las VMs de DSPM antes del terraform apply
# Subscription: 86d359e5-24fc-4007-9040-6b4de4727f31

set -euo pipefail

SUBSCRIPTION_ID=os.getenv("AZURE_SUBSCRIPTION_ID")
DSPM_RG_PATTERN="trendmicro-v1-dspm-*"

echo "======================================================"
echo " DSPM VM Shutdown — pre Terraform apply"
echo " Subscription: $SUBSCRIPTION_ID"
echo "======================================================"

az account set --subscription "$SUBSCRIPTION_ID"

echo ""
echo "[1/3] Buscando resource groups DSPM..."
RGS=$(az group list \
  --query "[?starts_with(name, 'trendmicro-v1-dspm')].name" \
  -o tsv)

if [[ -z "$RGS" ]]; then
  echo "  ✓ Nenhum resource group DSPM encontrado. Nada a fazer."
  exit 0
fi

echo "  Resource groups encontrados:"
echo "$RGS" | sed 's/^/    - /'

echo ""
echo "[2/3] Buscando VMs em execução..."

FOUND=0
VM_LIST=()

while IFS= read -r rg; do
  VMS=$(az vm list \
    --resource-group "$rg" \
    --query "[].{name:name, rg:resourceGroup, status:provisioningState}" \
    -o tsv 2>/dev/null || true)

  if [[ -z "$VMS" ]]; then
    echo "  [$rg] nenhuma VM encontrada"
    continue
  fi

  while IFS=$'\t' read -r vm_name vm_rg _; do
    POWER=$(az vm get-instance-view \
      --name "$vm_name" \
      --resource-group "$vm_rg" \
      --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" \
      -o tsv 2>/dev/null || echo "Unknown")

    echo "  [$vm_rg] $vm_name → $POWER"
    VM_LIST+=("$vm_name|$vm_rg|$POWER")
    FOUND=$((FOUND + 1))
  done <<< "$VMS"

done <<< "$RGS"

if [[ $FOUND -eq 0 ]]; then
  echo ""
  echo "  ✓ Nenhuma VM DSPM encontrada. Pronto para terraform apply."
  exit 0
fi

echo ""
echo "[3/3] Desligando VMs..."

ERRORS=0
for entry in "${VM_LIST[@]}"; do
  IFS='|' read -r vm_name vm_rg power_state <<< "$entry"

  if [[ "$power_state" == "VM deallocated" ]]; then
    echo "  [SKIP] $vm_name já está deallocated"
    continue
  fi

  echo -n "  [STOP] $vm_name ($vm_rg)... "

  if az vm deallocate \
      --name "$vm_name" \
      --resource-group "$vm_rg" \
      --no-wait \
      --output none 2>/dev/null; then
    echo "deallocate iniciado"
  else
    echo "ERRO ao iniciar deallocate"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
echo "======================================================"
if [[ $ERRORS -gt 0 ]]; then
  echo " ⚠  Concluído com $ERRORS erro(s). Verifique antes do apply."
  exit 1
else
  echo " ✓  Deallocate iniciado para todas as VMs."
  echo ""
  echo " Aguarde ~2 min e verifique o status com:"
  echo "   az vm list --subscription $SUBSCRIPTION_ID \\"
  echo "     --query \"[].{name:name,rg:resourceGroup}\" -o table"
  echo ""
  echo " Depois execute: terraform apply"
  exit 0
fi