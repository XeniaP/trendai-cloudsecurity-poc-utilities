#!/bin/bash

PREFIX="v1-avtd"
REGION="us-east4" 

PROJECTS=$(gcloud projects list --filter="lifecycleState=ACTIVE" --format="value(projectId)")

echo "Se han detectado los siguientes proyectos para limpieza:"
echo "$PROJECTS"
echo "--------------------------------------------------------"

for PROJECT_ID in $PROJECTS; do
    echo ">> TRABAJANDO EN EL PROYECTO: $PROJECT_ID"
    gcloud config set project $PROJECT_ID --quiet

    # 1. CLOUD RUN (Services, Jobs y Worker Pools)
    echo "   - Eliminando Cloud Run..."
    gcloud run services list --filter="metadata.name:$PREFIX" --format="value(metadata.name)" --region=$REGION | xargs -r -I {} gcloud run services delete {} --region=$REGION --quiet
    gcloud run jobs list --filter="metadata.name:$PREFIX" --format="value(metadata.name)" --region=$REGION | xargs -r -I {} gcloud run jobs delete {} --region=$REGION --quiet

    # 2. EVENTARC & WORKFLOWS
    echo "   - Eliminando Triggers y Workflows..."
    gcloud eventarc triggers list --filter="name:$PREFIX" --format="value(name)" --location=$REGION | xargs -r -I {} gcloud eventarc triggers delete {} --location=$REGION --quiet
    gcloud workflows delete "${PREFIX}-disk-scan-workflow" --location=$REGION --quiet 2>/dev/null

    # 3. PUB/SUB (Subscriptions & Topics)
    echo "   - Eliminando Pub/Sub..."
    gcloud pubsub subscriptions list --filter="name:$PREFIX" --format="value(name)" | xargs -r -I {} gcloud pubsub subscriptions delete {} --quiet
    gcloud pubsub topics list --filter="name:$PREFIX" --format="value(name)" | xargs -r -I {} gcloud pubsub topics delete {} --quiet

    # 4. STORAGE BUCKETS
    echo "   - Eliminando Buckets con prefijo $PREFIX..."
    gsutil ls | grep "$PREFIX" | xargs -r -I {} gsutil rm -r {}

    # 5. SECRET MANAGER
    echo "   - Eliminando Secretos..."
    gcloud secrets list --filter="name:$PREFIX" --format="value(name)" | xargs -r -I {} gcloud secrets delete {} --quiet

    # 6. LOGGING SINKS
    echo "   - Eliminando Logging Sinks..."
    gcloud logging sinks list --filter="name:$PREFIX" --format="value(name)" | xargs -r -I {} gcloud logging sinks delete {} --quiet

    # 7. IAM: ROLES Y SERVICE ACCOUNTS
    echo "   - Eliminando identidades IAM (Roles: v1-avtd / Vision One CAM)..."
    # Borrar roles que empiecen con v1-avtd o contengan Vision_One_CAM
    gcloud iam roles list --project=$PROJECT_ID --format="value(name)" | grep -E "v1-avtd|Vision_One_CAM" | xargs -r -I {} gcloud iam roles delete {} --project=$PROJECT_ID --quiet
    # Service Accounts
    gcloud iam service-accounts list --filter="email:$PREFIX" --format="value(email)" | xargs -r -I {} gcloud iam service-accounts delete {} --quiet

    # 8. WORKLOAD IDENTITY
    echo "   - Eliminando Workload Identity Pools..."
    gcloud iam workload-identity-pools list --location="global" --filter="name:$PREFIX" --format="value(name)" | xargs -r -I {} gcloud iam workload-identity-pools delete {} --location="global" --quiet

    # 9. NETWORKING (Firewalls, Subnets, VPC)
    echo "   - Eliminando Networking (VPC e infraestructura)..."
    gcloud compute firewall-rules list --filter="name:$PREFIX" --format="value(name)" | xargs -r -I {} gcloud compute firewall-rules delete {} --quiet
    
    # Intentar borrar subred específica y red específica
    gcloud compute networks subnets delete "${PREFIX}-vpc-subnet-$REGION" --region=$REGION --quiet 2>/dev/null
    gcloud compute networks delete "${PREFIX}-vpc-network" --quiet 2>/dev/null

    echo ">> Finalizado limpieza en $PROJECT_ID"
    echo "--------------------------------------------------------"
done

echo "PROCESO GLOBAL FINALIZADO."