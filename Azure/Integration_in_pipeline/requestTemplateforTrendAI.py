import os
import sys
import json
import zipfile
from io import BytesIO
import requests


url = "https://api.xdr.trendmicro.com/beta/cam/azureSubscriptions/generateTerraformPackage"

OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "cloud-account-management-terraform-package")
ZIP_NAME = os.environ.get("ZIP_NAME", "cloud-account-management-terraform-package.zip")

v1_api_key=os.getenv("V1_API_KEY")
subscription_id=os.getenv("SUB_ID")
subscription_name=os.getenv("CLOUD_ACCOUNT_NAME")
swp_instance_id=os.getenv("SWP_INSTANCE_ID")
avtd_regions=os.getenv("AVTD_REGIONS")
dspm_regions=os.getenv("DSPM_REGIONS")
main_region=os.getenv("MAIN_REGION")

payload = {} # Initialize payload as an empty dictionary

headers = {
  'Content-Type': 'application/json',
  'Accept': 'application/json',
  'Authorization': f'Bearer {v1_api_key}'
}

if main_region is None or main_region == "":
    main_region = "eastus"

print("Main region is set to: ", main_region)
print("AVTD regions: ", avtd_regions)
print("DSPM regions: ", dspm_regions)


def request_template_url():
    print("Requesting template URL with the following parameters:")
    print(f"Subscription Name: {subscription_name}")
    print(f"Subscription ID: {subscription_id}")
    payload = {
        "azureSubscriptionName": f"{subscription_name}",
        "azureSubscriptionDescription": "",
        "subscriptionId": f"{subscription_id}",
        "connectedSecurityServices": [
            {
            "name": "workload",
            "instanceIds": [
                f"{swp_instance_id}"
            ]
            }
        ],
        "features": [
            {
            "id": "file-storage-security",
            "regions": [main_region]
            },
            {
            "id": "real-time-posture-monitoring"
            }
        ],
        "azureRegion": main_region,
        "isCAMCloudASRMEnabled": True
    }

    if avtd_regions != "[]":
        print("avtd")
        featureConfig = {
            "id": "cloud-sentry",
            "regions": avtd_regions.split(",")
        }
        payload["features"].append(featureConfig)
    
    if dspm_regions != "[]":
        print("dspm")
        featureConfig = {
            "id": "data-security-posture-management",
            "regions": dspm_regions.split(",")
        }
        payload["features"].append(featureConfig)
    
    print("Payload to be sent in the request: ", payload)

    response = requests.request("POST", url, headers=headers, data=json.dumps(payload))
    print("Response status code: ", response.text)

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