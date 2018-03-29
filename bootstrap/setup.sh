#!/bin/bash

#set -x

APP_NAME="rainbow-app"
APP_PORT="30080" # range 30000-32767
CLUSTER_NAME="${APP_NAME}-k8s-cluster"
CLOUDSDK_CONTAINER_USE_V1_API_CLIENT=false

#export MY_REGIONS="us-west1 us-central1 us-west1 europe-west1 europe-west3"
MY_REGIONS="europe-west1 europe-west3"

##Create K8sclusters
for r in ${MY_REGIONS}
  do
    echo ${r}
    MY_ZONES=( $( gcloud compute zones list | grep ${r} | awk '{print $1 }' | head -3 | tr '\n' ' ' ) )
    echo ${MY_ZONES[*]}
    echo "------------"
    gcloud container clusters create ${CLUSTER_NAME} --num-nodes 1 --tags=${CLUSTER_NAME},${r} \
    --zone ${MY_ZONES[0]} --node-locations=${MY_ZONES[0]},${MY_ZONES[1]},${MY_ZONES[2]}
    echo "------------"
done

## Reserve global IP address
gcloud compute addresses create ${CLUSTER_NAME}-gip --ip-version=IPV4 --global

## Create HealthCheck: "tcp:80"/"http:80"
gcloud compute health-checks create tcp --port=${APP_PORT} --port-name="${APP_NAME}-port" http-custom-healthcheck

## Create Backend Service
gcloud compute backend-services create "${APP_NAME}-backend-service" \
    --protocol HTTP \
    --port-name "${APP_NAME}-port" \
    --health-checks http-custom-healthcheck \
    --global

## Get Instance Groups
INSTANCE_GROUPS=$(gcloud compute instance-groups managed list | grep -v AUTOSCALED | awk '{print $1}')

## Set Instance Groups set-named-ports and Add to Backend Service
for ig in ${INSTANCE_GROUPS}
  do
    INSTANCE_GROUP_Z=$(gcloud compute instance-groups managed list | grep -v AUTOSCALED | grep ${ig} |awk '{print $2}')

    gcloud compute instance-groups managed set-named-ports ${ig} \
    --named-ports "${APP_NAME}-port":${APP_PORT} \
    --zone ${INSTANCE_GROUP_Z}

    sleep 5

    gcloud compute backend-services add-backend "${APP_NAME}-backend-service" \
      --balancing-mode UTILIZATION \
      --max-utilization 0.8 \
      --capacity-scaler 1 \
      --instance-group ${ig} \
      --instance-group-zone ${INSTANCE_GROUP_Z} \
      --global
done

## Create default URL-Map
gcloud compute url-maps create "${APP_NAME}-map" \
    --default-service "${APP_NAME}-backend-service"

## Create Target-LB-Proxy
gcloud compute target-http-proxies create "${APP_NAME}-lb-proxy" \
    --url-map "${APP_NAME}-map"

## Get Reserved IP address
GLOBAL_IP_ADDRESS=$(gcloud compute addresses list | grep -v STATUS | grep ${CLUSTER_NAME}-gip | awk '{print $2}')

## Create global forwarding rule to route incoming requests to the proxy
gcloud compute forwarding-rules create "${APP_NAME}-frwd-rule" \
    --address ${GLOBAL_IP_ADDRESS} \
    --global \
    --target-http-proxy "${APP_NAME}-lb-proxy" \
    --ports 80

## Global Forwarding Rules Info
gcloud compute forwarding-rules list

## Get Docker Build Deploy config (to temp file)
gcloud container clusters list

export CLUSTER_LIST=$(gcloud container clusters list | grep RUNNING | awk '{print $2}')
echo ${CLUSTER_LIST}

:> cloudbuild.temp.yaml
for i in ${CLUSTER_LIST}
  do
      echo "
- id: kubectl-apply-${i}
  name: 'gcr.io/cloud-builders/kubectl'
  args: ['apply', '-f', 'k8s/']
  env:
  - 'CLOUDSDK_COMPUTE_ZONE=${i}'
  - 'CLOUDSDK_CONTAINER_CLUSTER=${CLUSTER_NAME}'" >> cloudbuild.temp.yaml
done

## Allow Cloud Builder access to the k8s clusters
MY_PROJECT="$(gcloud projects describe \
    $(gcloud config get-value core/project -q) --format='get(projectNumber)')"

gcloud projects add-iam-policy-binding $MY_PROJECT \
    --member=serviceAccount:$MY_PROJECT@cloudbuild.gserviceaccount.com \
    --role=roles/container.developer

## To submit a build using the build config
TEMPO_SHA=$(echo -n $(date) | sha256sum | cut -c -7)
cat ../cloudbuild.yaml cloudbuild.temp.yaml > cloudbuild.merged.yaml

gcloud container builds submit --config cloudbuild.merged.yaml \
--substitutions=REPO_NAME=rainbow-app,BRANCH_NAME=bootstrap,SHORT_SHA=${TEMPO_SHA} ../

