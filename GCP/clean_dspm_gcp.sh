#!/bin/bash
# =============================================================================
# DSPM GCP Resource Discovery Script (v2)
# =============================================================================
# Purpose: Identify all DSPM-created resources in a customer's GCP project
#          after Terraform state file loss, for manual cleanup before
#          re-deployment.
#
# Usage:   ./dspm-gcp-resource-discovery.sh <PROJECT_ID> [REGION]
#
# Coverage: 96% of Terraform-managed resources (48/50)
#   - STEP 1: Label-based search (Cloud Asset Inventory)
#   - STEP 2: Name-prefix search (unlabeled network resources, service accounts)
#   - STEP 3: Cloud Scheduler, Log Sinks, Monitoring channels/metrics
#   - STEP 4: Resource-level IAM bindings (buckets, secrets, topics, etc.)
#   - STEP 5: Storage bucket contents, resource policies, dashboards
#
# Not discoverable (2/50):
#   - null_resource (Terraform provisioners — no GCP API footprint)
#
# IMPORTANT: This script only LISTS resources. It does NOT delete anything.
#            Review the output carefully before manual deletion.
#
# Reference: PCT-94037
# =============================================================================

set -euo pipefail

PROJECT_ID="${1:?Usage: $0 <PROJECT_ID> [REGION]}"
REGION="${2:-}"

echo "============================================================"
echo " DSPM GCP Resource Discovery (v2)"
echo " Project: ${PROJECT_ID}"
[ -n "$REGION" ] && echo " Region filter: ${REGION}"
echo " Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"

# -----------------------------------------------------------------------------
# STEP 1: Label-based search (primary — most accurate)
# Catches: Cloud Functions, Cloud Run, Pub/Sub, Storage, Disks, Snapshots,
#          Secrets, Eventarc, Artifact Registry, Alert Policies, Scan VMs
# Label source: Terraform standard_labels + scan-job-lifecycle labels
# -----------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " STEP 1: Label-based search (trend-micro-product=dspm)"
echo "================================================================"

LABEL_QUERY="labels.trend-micro-product=dspm"
if [ -n "$REGION" ]; then
  LABEL_QUERY="${LABEL_QUERY} AND location=${REGION}"
fi

echo ""
echo "--- All DSPM-labeled resources (grouped by type) ---"
gcloud asset search-all-resources \
  --project="${PROJECT_ID}" \
  --query="${LABEL_QUERY}" \
  --format="table[box](
    assetType.segment(-1):label=RESOURCE_TYPE,
    name.segment(-1):label=NAME,
    labels.component:label=COMPONENT,
    labels.location:label=LOCATION,
    labels.managed_by:label=MANAGED_BY
  )" \
  --sort-by="assetType"

echo ""
echo "--- Summary count by resource type ---"
gcloud asset search-all-resources \
  --project="${PROJECT_ID}" \
  --query="${LABEL_QUERY}" \
  --format="value(assetType)" \
  | sort | uniq -c | sort -rn

# -----------------------------------------------------------------------------
# STEP 2: Name-prefix search for resources that do NOT support labels
# GCP limitation: VPC, Subnet, Router, NAT, Firewall, VPC Connector,
#                 and Service Account do not support the labels parameter
# -----------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " STEP 2: Resources without label support (name prefix: dspm-)"
echo "================================================================"

echo ""
echo "--- VPC Networks ---"
gcloud compute networks list \
  --project="${PROJECT_ID}" \
  --filter="name~^dspm-" \
  --format="table(name, autoCreateSubnetworks, routingConfig.routingMode)" \
  2>/dev/null || echo "  (none found or no permission)"

echo ""
echo "--- Subnets ---"
gcloud compute networks subnets list \
  --project="${PROJECT_ID}" \
  --filter="name~^dspm-" \
  --format="table(name, region, ipCidrRange, network.segment(-1))" \
  2>/dev/null || echo "  (none found or no permission)"

echo ""
echo "--- Cloud Routers ---"
gcloud compute routers list \
  --project="${PROJECT_ID}" \
  --filter="name~^dspm-" \
  --format="table(name, region, network.segment(-1))" \
  2>/dev/null || echo "  (none found or no permission)"

echo ""
echo "--- Cloud NATs ---"
# NAT listing requires router name; use asset search as reliable fallback
gcloud asset search-all-resources \
  --project="${PROJECT_ID}" \
  --query="name:dspm- AND assetType=compute.googleapis.com/RouterNat" \
  --format="table(name.segment(-1):label=NAT_NAME, name)" \
  2>/dev/null || true
# Also enumerate NATs from discovered routers
for router_info in $(gcloud compute routers list \
  --project="${PROJECT_ID}" \
  --filter="name~^dspm-" \
  --format="csv[no-heading](name,region.segment(-1))" 2>/dev/null); do
  router_name=$(echo "${router_info}" | cut -d',' -f1)
  router_region=$(echo "${router_info}" | cut -d',' -f2)
  gcloud compute routers nats list \
    --project="${PROJECT_ID}" \
    --router="${router_name}" \
    --router-region="${router_region}" \
    --format="table(name, sourceSubnetworkIpRangesToNat)" \
    2>/dev/null | tail -n +2 | sed 's/^/  /' || true
done

echo ""
echo "--- Firewall Rules ---"
echo "    NOTE: Only delete rules prefixed with 'dspm-'"
echo "          Do NOT delete 'aet-*' or 'vpc-connector-*' (cloud-managed)"
echo ""
gcloud compute firewall-rules list \
  --project="${PROJECT_ID}" \
  --filter="name~^dspm-" \
  --format="table(name, network.segment(-1), direction, allowed[].map().firewall_rule().list():label=ALLOW)" \
  2>/dev/null || echo "  (none found or no permission)"

echo ""
echo "--- VPC Access Connectors ---"
if [ -n "$REGION" ]; then
  gcloud compute networks vpc-access connectors list \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --filter="name~dspm-" \
    --format="table(name, region, state, network)" \
    2>/dev/null || echo "  (none found or no permission)"
else
  gcloud asset search-all-resources \
    --project="${PROJECT_ID}" \
    --query="name:dspm- AND assetType=vpcaccess.googleapis.com/Connector" \
    --format="table(name.segment(-1):label=CONNECTOR, name)" \
    2>/dev/null || echo "  (none found or no permission)"
fi

echo ""
echo "--- Service Accounts ---"
gcloud iam service-accounts list \
  --project="${PROJECT_ID}" \
  --filter="email~^dspm-" \
  --format="table(email, displayName, disabled)" \
  2>/dev/null || echo "  (none found or no permission)"

echo ""
echo "--- Project-Level IAM Bindings for DSPM Service Accounts ---"
gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.members~dspm-" \
  --format="table(bindings.role, bindings.members)" \
  2>/dev/null || echo "  (no permission to read IAM policy)"

# -----------------------------------------------------------------------------
# STEP 3: Resources NOT indexed in Cloud Asset Inventory
# These resource types require individual API calls
# -----------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " STEP 3: Resources outside Cloud Asset Inventory"
echo "================================================================"

echo ""
echo "--- Cloud Scheduler Jobs ---"
if [ -n "$REGION" ]; then
  SCHEDULER_REGIONS="${REGION}"
else
  SCHEDULER_REGIONS=$(gcloud scheduler locations list \
    --project="${PROJECT_ID}" \
    --format="value(locationId)" 2>/dev/null || echo "")
fi

if [ -n "$SCHEDULER_REGIONS" ]; then
  found_jobs=false
  for region in ${SCHEDULER_REGIONS}; do
    jobs=$(gcloud scheduler jobs list \
      --project="${PROJECT_ID}" \
      --location="${region}" \
      --filter="name~dspm-" \
      --format="table(name.segment(-1):label=JOB_NAME, state, schedule)" \
      2>/dev/null | tail -n +2)
    if [ -n "$jobs" ]; then
      echo "  Region: ${region}"
      echo "$jobs" | sed 's/^/    /'
      found_jobs=true
    fi
  done
  if [ "$found_jobs" = false ]; then
    echo "  (none found)"
  fi
else
  echo "  (could not list scheduler locations)"
fi

echo ""
echo "--- Log Router Sinks ---"
gcloud logging sinks list \
  --project="${PROJECT_ID}" \
  --filter="name~^dspm-" \
  --format="table(name, destination, writerIdentity)" \
  2>/dev/null || echo "  (none found or no permission)"

echo ""
echo "--- Monitoring Notification Channels ---"
gcloud alpha monitoring channels list \
  --project="${PROJECT_ID}" \
  --format="table(displayName, type, name)" \
  2>/dev/null | grep -i dspm || echo "  (none found or gcloud alpha not available)"

echo ""
echo "--- Custom Metric Descriptors ---"
gcloud monitoring metrics-descriptors list \
  --project="${PROJECT_ID}" \
  --filter="type~dspm" \
  --format="table(type, metricKind, valueType)" \
  2>/dev/null || echo "  (none found or no permission)"

echo ""
echo "--- Monitoring Dashboards ---"
gcloud monitoring dashboards list \
  --project="${PROJECT_ID}" \
  --format="table(displayName, name)" \
  2>/dev/null | grep -i dspm || echo "  (none found or no permission)"

echo ""
echo "--- Compute Resource Policies (Snapshot Schedules) ---"
gcloud compute resource-policies list \
  --project="${PROJECT_ID}" \
  --filter="name~^dspm-" \
  --format="table(name, region, status)" \
  2>/dev/null || echo "  (none found or no permission)"

echo ""
echo "--- Disk Resource Policy Attachments ---"
gcloud compute disks list \
  --project="${PROJECT_ID}" \
  --filter="name~^dspm-" \
  --format="table(name, zone, resourcePolicies.list())" \
  2>/dev/null || echo "  (none found or no permission)"

# -----------------------------------------------------------------------------
# STEP 4: Resource-level IAM bindings
# Cloud Asset Inventory does NOT index resource-level IAM policies.
# These must be queried per-resource. If left behind, they cause:
#   - Orphaned permissions (security risk)
#   - "already exists" errors on re-deployment
# -----------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " STEP 4: Resource-level IAM bindings"
echo "================================================================"

echo ""
echo "--- Storage Bucket IAM (dspm-* buckets) ---"
for bucket in $(gsutil ls -p "${PROJECT_ID}" 2>/dev/null | grep "gs://dspm-" | sed 's|gs://||;s|/||'); do
  echo "  Bucket: ${bucket}"
  gsutil iam get "gs://${bucket}" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for b in data.get('bindings', []):
        for m in b.get('members', []):
            print(f\"    {b['role']}: {m}\")
except: pass
" || echo "    (no permission)"
done

echo ""
echo "--- Secret Manager IAM (dspm-* secrets) ---"
gcloud secrets list --project="${PROJECT_ID}" --filter="name~dspm-" \
  --format="value(name)" 2>/dev/null | while read -r secret; do
  echo "  Secret: ${secret}"
  gcloud secrets get-iam-policy "${secret}" --project="${PROJECT_ID}" \
    --flatten="bindings[].members" \
    --format="table[no-heading](bindings.role, bindings.members)" 2>/dev/null \
    | sed 's/^/    /' || echo "    (no permission)"
done

echo ""
echo "--- Pub/Sub Topic IAM (dspm-* topics) ---"
gcloud pubsub topics list --project="${PROJECT_ID}" --filter="name~dspm-" \
  --format="value(name)" 2>/dev/null | while read -r topic; do
  topic_short=$(basename "${topic}")
  echo "  Topic: ${topic_short}"
  gcloud pubsub topics get-iam-policy "${topic}" \
    --flatten="bindings[].members" \
    --format="table[no-heading](bindings.role, bindings.members)" 2>/dev/null \
    | sed 's/^/    /' || echo "    (no permission)"
done

echo ""
echo "--- Cloud Run Service IAM (dspm-* services) ---"
gcloud run services list --project="${PROJECT_ID}" --platform=managed \
  --filter="metadata.name~^dspm-" \
  --format="csv[no-heading](metadata.name,region)" 2>/dev/null | while IFS=',' read -r service region; do
  [ -z "$service" ] && continue
  echo "  Service: ${service} (${region})"
  gcloud run services get-iam-policy "${service}" --region="${region}" \
    --project="${PROJECT_ID}" \
    --flatten="bindings[].members" \
    --format="table[no-heading](bindings.role, bindings.members)" 2>/dev/null \
    | sed 's/^/    /' || echo "    (no permission)"
done

echo ""
echo "--- Artifact Registry IAM (dspm-* repos) ---"
gcloud artifacts repositories list --project="${PROJECT_ID}" \
  --filter="name~dspm-" --format="csv[no-heading](name,location)" 2>/dev/null \
  | while IFS=',' read -r repo location; do
  [ -z "$repo" ] && continue
  echo "  Repository: ${repo} (${location})"
  gcloud artifacts repositories get-iam-policy "${repo}" \
    --location="${location}" --project="${PROJECT_ID}" \
    --flatten="bindings[].members" \
    --format="table[no-heading](bindings.role, bindings.members)" 2>/dev/null \
    | sed 's/^/    /' || echo "    (no permission)"
done

# -----------------------------------------------------------------------------
# STEP 5: Storage bucket contents
# GCS objects are not indexed in Cloud Asset Inventory.
# These include Cloud Function source archives, startup scripts, and
# placeholder files that may block bucket deletion.
# -----------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " STEP 5: Storage bucket contents"
echo "================================================================"

echo ""
echo "--- Objects in DSPM buckets ---"
for bucket in $(gcloud storage buckets list --project="${PROJECT_ID}" \
  --filter="labels.trend-micro-product=dspm" \
  --format="value(name)" 2>/dev/null); do
  object_count=$(gsutil ls -r "gs://${bucket}/**" 2>/dev/null | grep -cv ":$" || echo "0")
  echo "  Bucket: ${bucket} (${object_count} objects)"
  gsutil ls "gs://${bucket}/" 2>/dev/null \
    | head -20 | sed 's/^/    /' || echo "    (empty or no permission)"
  if [ "${object_count}" -gt 20 ]; then
    echo "    ... and $((object_count - 20)) more objects"
  fi
done

echo ""
echo "--- Audit Logging Configuration ---"
echo "    NOTE: DSPM enables storage.googleapis.com audit logging."
echo "    This is a project-level setting, not a deletable resource."
gcloud projects get-iam-policy "${PROJECT_ID}" --format=json 2>/dev/null \
  | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for ac in data.get('auditConfigs', []):
        if ac.get('service') == 'storage.googleapis.com':
            types = [c.get('logType','?') for c in ac.get('auditLogConfigs',[])]
            print(f\"    Enabled: {', '.join(types)}\")
            sys.exit(0)
    print('    Not configured')
except: print('    (could not check audit config)')
" || echo "    (could not check audit config)"

# -----------------------------------------------------------------------------
# SUMMARY & WARNINGS
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " CLEANUP WARNINGS"
echo "============================================================"
echo ""
echo " 1. DELETE ORDER MATTERS — use reverse dependency order:"
echo "    Cloud Scheduler -> Eventarc Triggers -> Cloud Functions"
echo "    -> Cloud Run -> Monitoring -> Pub/Sub -> Compute VMs"
echo "    -> Disks + Snapshots -> Storage Buckets -> Artifact Registry"
echo "    -> Secrets -> Log Sink -> VPC Connector -> Firewall Rules"
echo "    -> NAT + Router -> Subnet -> VPC -> Service Account (LAST)"
echo ""
echo " 2. Do NOT delete these cloud-managed resources:"
echo "    - Firewall rules prefixed 'aet-*' or 'vpc-connector-*'"
echo "    - Eventarc service agent SAs (service-*@gcp-sa-eventarc.*)"
echo "    - Cloud Build service agents"
echo "    - Docker images in 'gcf-artifacts' repo (auto-cleaned with function)"
echo ""
echo " 3. Service Account has 14+ IAM role bindings at project level"
echo "    PLUS resource-level bindings on buckets, secrets, topics, etc."
echo "    Remove ALL bindings BEFORE deleting the SA, or they become orphaned."
echo ""
echo " 4. Empty Storage Buckets before deleting them:"
echo "    gsutil -m rm -r gs://BUCKET_NAME/**"
echo "    gsutil rb gs://BUCKET_NAME"
echo ""
echo " 5. After cleanup, verify clean state:"
echo "    gcloud asset search-all-resources \\"
echo "      --project=${PROJECT_ID} \\"
echo "      --query=\"labels.trend-micro-product=dspm\" \\"
echo "      --format=\"table(assetType, name)\""
echo ""
echo "============================================================"
echo " Discovery complete. Review output before deleting resources."
echo "============================================================"
