#!/bin/bash

PREFIX="v1-avtd"
REGION="us-east4" 

PROJECTS=$(gcloud projects list --filter="lifecycleState=ACTIVE" --format="value(projectId)")

echo "Se han detectado los siguientes proyectos para limpieza:"
echo "$PROJECTS"
echo "--------------------------------------------------------"

for PROJECT_ID in $PROJECTS; do
    echo ">> Project: $PROJECT_ID"
    gcloud config set project $PROJECT_ID --quiet

    gcloud run services list --filter="metadata.name:$PREFIX" --format="value(metadata.name)" --region=$REGION | xargs -r -I {} gcloud run services delete {} --region=$REGION --quiet
    gcloud run jobs list --filter="metadata.name:$PREFIX" --format="value(metadata.name)" --region=$REGION | xargs -r -I {} gcloud run jobs delete {} --region=$REGION --quiet

    gcloud eventarc triggers list --filter="name:$PREFIX" --format="value(name)" --location=$REGION | xargs -r -I {} gcloud eventarc triggers delete {} --location=$REGION --quiet
    gcloud workflows delete "${PREFIX}-disk-scan-workflow" --location=$REGION --quiet 2>/dev/null

    gcloud pubsub subscriptions list --filter="name:$PREFIX" --format="value(name)" | xargs -r -I {} gcloud pubsub subscriptions delete {} --quiet
    gcloud pubsub topics list --filter="name:$PREFIX" --format="value(name)" | xargs -r -I {} gcloud pubsub topics delete {} --quiet

    gsutil ls | grep "$PREFIX" | xargs -r -I {} gsutil rm -r {}
    gcloud secrets list --filter="name:$PREFIX" --format="value(name)" | xargs -r -I {} gcloud secrets delete {} --quiet

    gcloud logging sinks list --filter="name:$PREFIX" --format="value(name)" | xargs -r -I {} gcloud logging sinks delete {} --quiet
    gcloud iam roles list --project=$PROJECT_ID --format="value(name)" | grep -E "v1-avtd|Vision_One_CAM" | xargs -r -I {} gcloud iam roles delete {} --project=$PROJECT_ID --quiet
    gcloud iam service-accounts list --filter="email:$PREFIX" --format="value(email)" | xargs -r -I {} gcloud iam service-accounts delete {} --quiet

    TAG_KEY_NAME="vision-one-deployment-version"
    TAG_KEY_ID=$(gcloud resource-manager tags keys list --parent="projects/$PROJECT_ID" --format="value(name)" --filter="shortName=$TAG_KEY_NAME")

    if [ ! -z "$TAG_KEY_ID" ]; then
        echo "Eliminando Tag Key: $TAG_KEY_NAME ($TAG_KEY_ID)..."
        TAG_VALUES=$(gcloud resource-manager tags values list --parent=$TAG_KEY_ID --format="value(name)")
        for val in $TAG_VALUES; do
            gcloud resource-manager tags values delete $val --quiet
        done
        gcloud resource-manager tags keys delete $TAG_KEY_ID --quiet
        echo "Tag eliminado correctamente."
    else
        echo "No se encontró el Tag $TAG_KEY_NAME en el proyecto $PROJECT_ID."
    fi

    gcloud iam workload-identity-pools list --location="global" --filter="name:v1-workload-identity" --format="value(name)" | xargs -r -I {} gcloud iam workload-identity-pools delete {} --location="global" --quiet

    # 9. NETWORKING (Firewalls, Subnets, VPC)
    #echo "   - Eliminando Networking (VPC e infraestructura)..."
    #gcloud compute firewall-rules list --filter="name:$PREFIX" --format="value(name)" | xargs -r -I {} gcloud compute firewall-rules delete {} --quiet
    
    # Intentar borrar subred específica y red específica
    #gcloud compute networks subnets delete "${PREFIX}-vpc-subnet-$REGION" --region=$REGION --quiet 2>/dev/null
    #gcloud compute networks delete "${PREFIX}-vpc-network" --quiet 2>/dev/null

    echo ">> Finalizado limpieza en $PROJECT_ID"
    echo "--------------------------------------------------------"
done

echo "PROCESO GLOBAL FINALIZADO."