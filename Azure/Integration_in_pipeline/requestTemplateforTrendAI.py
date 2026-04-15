import requests
import json
import os

url = "https://api.xdr.trendmicro.com/beta/cam/azureSubscriptions/generateTerraformPackage"

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
    type(payload)
    print(avtd_regions == "[]")
    print(len(list(avtd_regions)))

    if avtd_regions != "[]":
        featureConfig = {
            "id": "cloud-sentry",
            "regions": avtd_regions.split(",")
        }
        payload["features"].append(featureConfig)
    
    if dspm_regions != "[]":
        featureConfig = {
            "id": "data-security-posture-management",
            "regions": dspm_regions.split(",")
        }
        payload["features"].append(featureConfig)
    
    print("Payload to be sent in the request: ", payload)

    response = requests.request("POST", url, headers=headers, data=json.dumps(payload))

    response_json = response.json()
    return response_json['templateUrl']

os.environ["BACKEND_URL"] = request_template_url()