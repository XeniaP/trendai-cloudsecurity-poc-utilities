#!/bin/bash
set -e

STORAGE_ACCOUNT="trendmicro-v1-$1"
PREFIX="camtfstate"

if [ -z "$STORAGE_ACCOUNT" ]; then
    echo "Error: Storage account name is required as an argument."
    exit 1
fi

echo "Starting search for containers with prefix '$PREFIX'..."

containers=$(az storage container list \
    --account-name "$STORAGE_ACCOUNT" \
    --query "[?starts_with(name, '$PREFIX')].name" -o tsv)

for container in $containers; do
    echo "Checking container: $container"
    blob_exists=$(az storage blob exists \
        --account-name "$STORAGE_ACCOUNT" \
        --container-name "$container" \
        --name "terraform.tfstate" \
        --query "exists" -o tsv)

    if [ "$blob_exists" == "true" ]; then
        lease_status=$(az storage blob show \
            --account-name "$STORAGE_ACCOUNT" \
            --container-name "$container" \
            --name "terraform.tfstate" \
            --query "properties.lease.status" -o tsv)

        if [ "$lease_status" == "locked" ]; then
            echo "  [BLOCK] Releasing lease in $container..."
            az storage blob lease break \
                --account-name "$STORAGE_ACCOUNT" \
                --container-name "$container" \
                --blob-name "terraform.tfstate"
        else
            echo "  [OK] No Locks"
        fi
    fi
done