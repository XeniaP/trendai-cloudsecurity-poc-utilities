import os
import sys
import json
import re
import zipfile
from io import BytesIO
import requests


url = "https://api.xdr.trendmicro.com/beta/cam/azureSubscriptions/generateTerraformPackage"

OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "cloud-account-management-terraform-package")
ZIP_NAME = os.environ.get("ZIP_NAME", "cloud-account-management-terraform-package.zip")

v1_api_key        = os.getenv("V1_API_KEY")
subscription_id   = os.getenv("SUB_ID")
subscription_name = os.getenv("CLOUD_ACCOUNT_NAME")
swp_instance_id   = os.getenv("SWP_INSTANCE_ID")
rtm_enable        = bool(os.getenv("RTM_ENABLE"))
fs_enable         = bool(os.getenv("FS_ENABLE"))
fss_region        = os.getenv("FSS_REGION")
cloud_xdr_enable  = False
main_region       = os.getenv("MAIN_REGION_RESOLVED")


def parse_regions(regions_env: str) -> list:
    """
    Normaliza el valor de una variable de entorno de regiones a una lista limpia.
    Maneja los siguientes formatos:
      - '["brazilsouth","eastus"]'  → JSON array string
      - 'brazilsouth,eastus'        → CSV plain
      - 'brazilsouth'               → single value
      - '[]' o '' o None            → lista vacía
    """
    if not regions_env or regions_env.strip() in ("[]", ""):
        return []

    stripped = regions_env.strip()

    if stripped.startswith("["):
        try:
            parsed = json.loads(stripped)
            return [r.strip() for r in parsed if isinstance(r, str) and r.strip()]
        except json.JSONDecodeError:
            pass

    # Fallback: CSV, eliminando corchetes y comillas residuales
    cleaned = re.sub(r'[\[\]"]', '', stripped)
    return [r.strip() for r in cleaned.split(",") if r.strip()]


# Parsear regiones al inicio, ya normalizadas
avtd_regions = parse_regions(os.getenv("AVTD_REGIONS", ""))
dspm_regions = parse_regions(os.getenv("DSPM_REGIONS", ""))

headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'Authorization': f'Bearer {v1_api_key}'
}

if not main_region:
    main_region = "eastus"

print("Main region is set to: ", main_region)
print("AVTD regions: ", avtd_regions)
print("DSPM regions: ", dspm_regions)
print("FS Enable: ", fs_enable)
print("FS Enable type: ", type(fs_enable))
print("FS Region: ", fss_region)
print("RTM Enable: ", rtm_enable)
print("XDR Enable: ", cloud_xdr_enable)


def request_template_url():
    print("Requesting template URL with the following parameters:")
    print(f"Subscription Name: {subscription_name}")
    print(f"Subscription ID: {subscription_id}")

    payload = {
        "azureSubscriptionName": subscription_name,
        "azureSubscriptionDescription": "",
        "subscriptionId": subscription_id,
        "connectedSecurityServices": [
            {
                "name": "workload",
                "instanceIds": [swp_instance_id]
            }
        ],
        "features": [],
        "azureRegion": main_region,
        "isCAMCloudASRMEnabled": True
    }

    if avtd_regions:
        payload["features"].append({
            "id": "cloud-sentry",
            "regions": avtd_regions
        })

    if dspm_regions:
        payload["features"].append({
            "id": "data-security-posture-management",
            "regions": dspm_regions
        })

    if rtm_enable:
        payload["features"].append({
            "id": "real-time-posture-monitoring"
        })

    if fs_enable:
        payload["features"].append({
            "id": "file-storage-security",
            "regions": [fss_region]
        })

    if cloud_xdr_enable:
        payload["features"].append({
            "id": "azure-activity-log"
        })

    print("Payload to be sent in the request: ", json.dumps(payload, indent=2))

    response = requests.post(url, headers=headers, data=json.dumps(payload))
    print("Response status code: ", response.status_code)
    print("Response body: ", response.text)

    response_json = response.json()
    return response_json['templateUrl']


def download_file(url: str, destination: str) -> None:
    with requests.get(url, stream=True, timeout=300) as response:
        response.raise_for_status()
        with open(destination, "wb") as f:
            for chunk in response.iter_content(chunk_size=8192):
                if chunk:
                    f.write(chunk)


def unzip_file(zip_path: str, extract_to: str) -> None:
    os.makedirs(extract_to, exist_ok=True)
    with zipfile.ZipFile(zip_path, "r") as zip_ref:
        zip_ref.extractall(extract_to)


def main() -> int:
    try:
        print("Generating Terraform package URL...")
        package_url = request_template_url()
        print(f"Package URL obtained: {package_url}")

        print(f"Downloading ZIP to: {ZIP_NAME}")
        download_file(package_url, ZIP_NAME)

        print(f"Extracting ZIP to: {OUTPUT_DIR}")
        unzip_file(ZIP_NAME, OUTPUT_DIR)

        print("Package downloaded and extracted successfully.")
        return 0

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
