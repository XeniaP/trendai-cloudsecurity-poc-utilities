import requests
import json
import os

url = "https://api.xdr.trendmicro.com/beta/cam/azureSubscriptions/generateTerraformPackage"

v1_api_key=os.getenv("API_KEY")
subscription_id=os.getenv("SUBSCRIPTION_ID")
subscription_name=os.getenv("SUBSCRIPTION_NAME")
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
    payload = json.dumps({
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
            "id": "cloud-sentry",
            "regions": avtd_regions.split(",")
            },
            {
            "id": "file-storage-security",
            "regions": [main_region]
            },
            {
            "id": "real-time-posture-monitoring"
            },
            {
            "id": "data-security-posture-management",
            "regions": dspm_regions.split(",")
            }
        ],
        "azureRegion": main_region,
        "isCAMCloudASRMEnabled": True
    })

    response = requests.request("POST", url, headers=headers, data=payload)

    response_json = response.json()
    print(response_json['templateUrl'])
    return response_json['templateUrl']

request_template_url()