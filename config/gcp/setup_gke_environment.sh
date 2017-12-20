#!/bin/sh

# Script to set up a new GKE (Kubernetes on Google Cloud Platform) environment based on the passed
# in ENV_NAME. Sets up associated GCP project as well. Must run from gcp/ directory.
# Usage: ./setup_gke_environment <ENV_NAME>

# Note: This script uses gcloud for all commands because many are not supported by the HTTP API,
# which would be preferable as we'd be able to easily check for OK status (200) for all calls, and
# be able to easily parse info from structured responses in json.
# Also, using the HTTP API requires creating an API key which cannot be scripted; it has to be done
# manually in Google Cloud Console (API -> Credentials).

if [[ $(pwd) != */gcp ]]; then
  echo "Please run out of /gcp directory. Aborting."
  exit 1
fi

source ./init_project_vars.sh
echo -e "Set project vars:
BASE_PROJECT_ID: ${BASE_PROJECT_ID}
  Prefix to use for all project IDs. Used with -ENV_NAME (e.g. dev, prod) as suffix.
ORGANIZATION_ID: ${ORGANIZATION_ID}
  ID of GCP organization
BILLING_ACCOUNT_ID: ${BILLING_ACCOUNT_ID}
  ID of GCP billing account
OWNERS: ${OWNERS}
  Project owners (comma separated list e.g. \"user:foo@foo.com\",\"group:bar-group@baz.com\")
"

if [[ -z ${BASE_PROJECT_ID} || \
      -z ${ORGANIZATION_ID} || \
      -z ${BILLING_ACCOUNT_ID} || \
      -z ${OWNERS} ]]; then
  echo "ERROR: Please make sure all variables for your project are set in init_project_vars.sh.
  See init_project_vars_example.sh."
fi

# Constants
INSTANCE_GROUP_SIZE=2 #Number of VMs to run for our GKE jobs
ZONE=us-central1-a
STATIC_BUCKET_NAME=static-bucket
NODE_PORT=30580 #If this changes, change nodePort in api-service.yaml too
HEALTH_CHECK_PORT=10256
BACKEND_SERVICE_NAME=api-backend-service
LB_NAME=portability-load-balancer
LB_EXTERNAL_IP_NAME=load-balancer-external-ip
LB_HTTPS_PROXY_NAME=load-balancer-https-proxy
LB_FORWARDING_RULE_NAME=portability-forwarding-rule
SSL_CERT_NAME=portability-cert
NUM_STEPS=27
CURR_STEP=0

print_step() {
  echo -e "\n$((++CURR_STEP))/${NUM_STEPS}. $1"
}

if [ -z $1 ]; then
  echo "ERROR: Must provide an environment, e.g. 'qa', 'test', or 'prod'"
  exit 1
fi

ENV=$1
PROJECT_ID="${BASE_PROJECT_ID}-$ENV"
gcloud=$(which gcloud)|| { echo "Google Cloud SDK (gcloud) not found." >&2; exit 1; }
gsutil=$(which gsutil)|| { echo "Google Cloud Storage CLI (gsutil) not found." >&2; exit 1; }
kubectl=$(which kubectl)|| { echo "Kubernetes CLI (kubectl) not found." >&2; exit 1; }

read -p "This script will install an SSL certificate on the project from your local filesystem soon.
You should get the cert ready now. It takes about 5 minutes. See this script for instructions.
Continue (y/N)? " response
response=${response,,} # to lower
if [[ ${response} =~ ^(yes|y| ) ]]; then
  echo "Continuing"
else
  echo "Aborting"
  exit 0
fi

# Instructions to obtain a free Letsencrypt SSL cert (5 mins):
# wget https://dl.eff.org/certbot-auto
# chmod a+x certbot-auto
# ./certbot-auto certonly --agree-tos --renew-by-default --manual --preferred-challenges=dns \
# -d your-domain-name.net,www.your-domain-name.net
# Enter the text records and wait 1-2 minutes and confirm
# It should save cert as follows:
# Your certificate and chain have been saved at:
# /etc/letsencrypt/live/gardenswithoutwalls-qa.net/fullchain.pem
# Your key file has been saved at:
# /etc/letsencrypt/live/gardenswithoutwalls-qa.net/privkey.pem
# Note: it is easiest to then sudo cp these files to a temporary location since the default
# file permissions are difficult.

read -p "Please enter the path to the certificate file (.crt or .pem): " CRT_FILE_PATH
if [[ ! -e ${CRT_FILE_PATH} ]]; then
  echo -e "No file found at ${CRT_FILE_PATH}. Aborting."
  exit 1
fi

read -p "Please enter the path to the key file (.key or .pem): " KEY_FILE_PATH
if [[ ! -e ${KEY_FILE_PATH} ]]; then
  echo -e "No file found at ${KEY_FILE_PATH}. Aborting."
  exit 1
fi

print_step
read -p "Creating project ${PROJECT_ID}. Continue (y/N)? " response
response=${response,,} # to lower
if [[ ${response} =~ ^(yes|y| ) ]]; then
  echo "Continuing"
else
  echo "Aborting"
  exit 0
fi
gcloud projects create ${PROJECT_ID} --name=${PROJECT_ID} --organization=$ORGANIZATION_ID

print_step
read -p "Changing your default project for gcloud to ${PROJECT_ID}. Continue (y/N)? " response
response=${response,,} # to lower
if [[ ${response} =~ ^(yes|y| ) ]]; then
# Set default project so any gcloud or gsutil commands that don't accept a project ID flag will
# (hopefully) use the correct one from gcloud's default config. This seems to work.
gcloud config set project ${PROJECT_ID}
else
  echo "Aborting"
  exit 0
fi

print_step "Creating a service account for IAM"
gcloud iam --project ${PROJECT_ID} service-accounts create ${PROJECT_ID} --display-name "${PROJECT_ID} service account"
SERVICE_ACCOUNT="${PROJECT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
echo -e "\nCreated service account:"
gcloud iam --project ${PROJECT_ID} service-accounts describe ${SERVICE_ACCOUNT}

print_step "Setting up IAM policy and ownership permissions"
# Save a copy of iam-policy.json before we substitute in our vars
cp iam-policy.json temp-iam-policy.json
# Substitute in the appropriate users/groups for our iam policy
sed -i "s|SERVICE_ACCOUNT|${SERVICE_ACCOUNT}|g" "iam-policy.json"
sed -i "s|\"OWNERS\"|${OWNERS}|g" "iam-policy.json"
print_step "Setting the following IAM policy \n"
cat iam-policy.json
read -p "
Continue (Y/n)? " response
if [[ ${response} =~ ^(no|n| ) ]]; then
  # Restore IAM policy to previous state
  mv temp-iam-policy.json iam-policy.json
  echo "Aborting"
  exit 0
fi
gcloud projects set-iam-policy ${PROJECT_ID} iam-policy.json
# Restore IAM policy to previous state
mv temp-iam-policy.json iam-policy.json

print_step "Enabling billing" # Needed for installing SSL cert
gcloud alpha billing projects link ${PROJECT_ID} --billing-account=$BILLING_ACCOUNT_ID

print_step "Enabling APIs"
# Needed for 'gcloud compute'
gcloud services --project ${PROJECT_ID} enable compute.googleapis.com
# Needed for managing container images
gcloud services --project ${PROJECT_ID} enable containerregistry.googleapis.com
# Needed for storing job state in Cloud DataStore
gcloud services --project ${PROJECT_ID} enable datastore.googleapis.com
# Needed for encrypting app secrets
gcloud services --project ${PROJECT_ID} enable cloudkms.googleapis.com

print_step "Installing SSL certificate"
gcloud compute ssl-certificates create ${SSL_CERT_NAME} \
    --certificate ${CRT_FILE_PATH} --private-key ${KEY_FILE_PATH}

print_step "Creating GCS 'static' bucket"
BUCKET_NAME="static-$PROJECT_ID"
GCS_BUCKET_NAME="gs://$BUCKET_NAME/"
gsutil mb -p ${PROJECT_ID} ${GCS_BUCKET_NAME}
echo "Created GCS bucket $GCS_BUCKET_NAME"

print_step "Creating backend 'static' bucket"
gcloud compute --project ${PROJECT_ID} backend-buckets create ${STATIC_BUCKET_NAME} --gcs-bucket-name=${BUCKET_NAME}
# TODO use --enable-cdn flag when we are ready to use CDN

print_step "Creating GCS 'app-data' bucket for storing encrypted app secrets"
BUCKET_NAME="app-data-$PROJECT_ID"
GCS_BUCKET_NAME="gs://$BUCKET_NAME/"
gsutil mb -p ${PROJECT_ID} ${GCS_BUCKET_NAME}
echo "Created GCS bucket $GCS_BUCKET_NAME"

print_step "Granting service account ${SERVICE_ACCOUNT} viewer privileges to 'app-data' bucket"
gsutil acl -p ${PROJECT_ID} ch -u ${SERVICE_ACCOUNT}:R ${GCS_BUCKET_NAME}

print_step "Creating a key to encrypt app secrets"
gcloud kms keyrings create portability_secrets --location global
# Currently only one purposes is supported: "encryption". Can't have separate encrypt/decrypt keys.
gcloud kms keys create portability_secrets_key --location global --keyring portability_secrets \
--purpose encryption

# Note: May want to enable autoscaling at some point
print_step "Creating GKE cluster. This will create a VM instance group automatically."
gcloud container clusters create portability-api-cluster --zone ${ZONE} \
--num-nodes=${INSTANCE_GROUP_SIZE} --image-type=COS \
--cluster-ipv4-cidr=10.4.0.0/14

print_step "Setting kubectl context for ${PROJECT_ID}"
gcloud container clusters get-credentials portability-api-cluster --zone ${ZONE}

KUBECTL_CONTEXT=$(kubectl config current-context)
print_step
read -p "Confirm we are using the correct Kubernetes context for ${PROJECT_ID}. Current context is:
${KUBECTL_CONTEXT}.
Continue (y/N)? " response
response=${response,,} # to lower
if [[ ${response} =~ ^(yes|y| ) ]]; then
  echo "Continuing"
else
  echo "Aborting"
  exit 0
fi

print_step "Creating health check for backend service and instance group"
gcloud compute http-health-checks create portability-health-check --port=${NODE_PORT} \
--request-path=/healthz --port=${HEALTH_CHECK_PORT}

# Setting named port on instance group. First, have to get the name of the instance group. This
# is auto generated by GKE cluster creation above and we can't change it. :(
INSTANCE_GROUPS=$(gcloud compute instance-groups list)
# Sample response:
# gcloud compute instance-groups list
# NAME                           LOCATION       SCOPE  NETWORK  MANAGED  INSTANCES
# foo-clus-default-pool-bar-grp  us-central1-a  zone   default  Yes      2
# Note: Response parsing is messy; see note at top for why we use gcloud and not HTTP API for this.
echo -e "Instance groups: \n${INSTANCE_GROUPS}"
if [[ -z ${INSTANCE_GROUPS} ]] ; then
  echo "Cluster did not create instance group as expected"
  exit 1
else
  # Split instance groups response. The array is evaluated using the delimiters stored in IFS.
  # Restore IFS to its original state when done.
  OIFS=$IFS
  IFS=$' \t\n'
  ARRAY=(${INSTANCE_GROUPS})
  INSTANCE_GROUP_NAME=${ARRAY[6]} # Grabs 'foo-clus-default-pool-bar-grp' from sample response
  IFS=${OIFS}
fi

print_step "Setting named port 'http' on instance group ${INSTANCE_GROUP_NAME}"
gcloud compute instance-groups set-named-ports ${INSTANCE_GROUP_NAME} \
--named-ports=http:${NODE_PORT} --zone=${ZONE}

# TODO: Uncomment as soon as 'gcloud compute instance-groups managed set-autohealing' is GA. It is
# currently in alpha (gcloud alpha compute) which requires project to be whitelisted. For now, have
# to do this step manually. There is an instruction for this at the end.
# print_step "Set health check on instance group ${INSTANCE_GROUP_NAME}"
# gcloud compute instance-groups managed set-autohealing portability-auto-healing \
# --http-health-check=portability-health-check --zone=${ZONE}

print_step "Creating GCP backend service '${BACKEND_SERVICE_NAME}'"
gcloud compute backend-services create ${BACKEND_SERVICE_NAME} \
--port=80 --port-name=http --protocol=HTTP --global --http-health-checks=portability-health-check

print_step "Adding instance group ${INSTANCE_GROUP_NAME} as a backend to ${BACKEND_SERVICE_NAME}"
gcloud compute backend-services add-backend ${BACKEND_SERVICE_NAME} \
--instance-group=${INSTANCE_GROUP_NAME} --balancing-mode=UTILIZATION --global \
--instance-group-zone=${ZONE}

print_step "Creating credentials for service account to access GCP APIs"
gcloud iam service-accounts keys create \
    /tmp/key.json \
    --iam-account=${SERVICE_ACCOUNT}

print_step "Importing the credentials as a Kubernetes Secret"
kubectl create secret generic portability-service-account-creds --from-file=key.json=/tmp/key.json
rm /tmp/key.json

print_step "Creating Kubernetes service portability.api"
kubectl create -f ../k8s/api-service.yaml

print_step "Creating load balancer"
gcloud compute url-maps create ${LB_NAME} \
--default-service ${BACKEND_SERVICE_NAME}
gcloud compute url-maps add-path-matcher ${LB_NAME} \
--default-service ${BACKEND_SERVICE_NAME} --path-matcher-name "static-bucket-mapping" \
--backend-bucket-path-rules "/static/*=${STATIC_BUCKET_NAME}"

print_step "Reserving a static external IP"
gcloud compute addresses create ${LB_EXTERNAL_IP_NAME} --global
EXTERNAL_IPS=$(gcloud compute addresses list)
# Sample response:
# gcloud compute addresses list
# NAME                       REGION  ADDRESS         STATUS
# load-balancer-external-ip          35.201.127.254  IN_USE
# Note: Response parsing is messy; see note at top for why we use gcloud and not HTTP API for this.
if [[ -z ${EXTERNAL_IPS} ]] ; then
  echo "Could not reserve external IP"
  exit 1
else
  # Split external IP response. The array is evaluated using the delimiters stored in IFS.
  # Restore IFS to its original state when done.
  OIFS=$IFS
  IFS=$' \t\n'
  ARRAY=(${EXTERNAL_IPS})
  EXTERNAL_IP_ADDRESS=${ARRAY[5]} # Grabs '35.201.127.254' from sample response
  IFS=${OIFS}
  echo -e "\nReserved external IP address: ${EXTERNAL_IP_ADDRESS}"
fi

print_step "Creating HTTPS proxy to our load balancer"
gcloud compute target-https-proxies create ${LB_HTTPS_PROXY_NAME} --url-map=${LB_NAME} \
--ssl-certificates=${SSL_CERT_NAME}

print_step "Creating global forwarding rule, i.e. load balancer 'frontend'"
gcloud compute forwarding-rules create ${LB_FORWARDING_RULE_NAME} \
    --address ${EXTERNAL_IP_ADDRESS} --ip-protocol TCP --ports=443 \
    --global --target-https-proxy ${LB_HTTPS_PROXY_NAME}

print_step "Creating a Kubernetes deployment"
IMAGE="gcr.io/$PROJECT_ID/portability-api:v1"
# Save a copy of api-deployment.yaml before we substitute in our vars
cp ../k8s/api-deployment.yaml ../k8s/temp-api-deployment.yaml
# Substitute in the current image to our deployment yaml
sed -i "s|IMAGE # Replaced by script|$IMAGE|g" "../k8s/api-deployment.yaml"
sed -i "s|PROJECT-ID # Replaced by script|$PROJECT_ID|g" "../k8s/api-deployment.yaml"
kubectl create -f ../k8s/api-deployment.yaml
# Restore api-deployment.yaml to previous state
mv ../k8s/temp-api-deployment.yaml ../k8s/api-deployment.yaml

print_step "Opening up VM firewall rule to allow requests from load balancer and health checkers"
# Find the firewall rule that is already applied to our VMs (it's the rule ending in "-vms").
# The rule is applied to our VMs via a network tag. Then open it up to LB and health checkers via
# allowed protocols/ports and source ranges.
HEALTH_CHECKER_IP_RANGES=209.85.152.0/22,209.85.204.0/22,35.191.0.0/16
LB_IP_RANGE=130.211.0.0/22
NETWORK_IP_RANGE=10.128.0.0/9
FIREWALL_RULES=$(gcloud compute firewall-rules list)
IFS=$'\n'
FIREWALL_RULES_ARRAY=($FIREWALL_RULES)
UPDATED_FIREWALL_RULE=false
for key in "${!FIREWALL_RULES_ARRAY[@]}"; do
  FIREWALL_RULE=${FIREWALL_RULES_ARRAY[$key]}
  IFS=$' \t'
  FIREWALL_RULE_ARRAY=($FIREWALL_RULE)
  FIREWALL_RULE_NAME=${FIREWALL_RULE_ARRAY[0]}
  if [[ $FIREWALL_RULE_NAME == *-vms ]]; then
    echo -e "Found vms firewall rule: $FIREWALL_RULE_NAME"
    EXISTING_ALLOWED_PROTOCOLS_PORTS=${FIREWALL_RULE_ARRAY[4]}
    UPDATE_FIREWALL_CMD="gcloud compute firewall-rules update $FIREWALL_RULE_NAME \
    --allow=tcp:${HEALTH_CHECK_PORT},tcp:${NODE_PORT},$EXISTING_ALLOWED_PROTOCOLS_PORTS \
    --source-ranges=${NETWORK_IP_RANGE},${HEALTH_CHECKER_IP_RANGES},${LB_IP_RANGE}"
    echo $UPDATE_FIREWALL_CMD
    ${UPDATE_FIREWALL_CMD}
    UPDATED_FIREWALL_RULE=true
  fi
done
if !(${UPDATED_FIREWALL_RULE}); then
  echo "Could not update firewall rule. Aborting"
  exit 1
fi

POSTPROCESS_SCRIPT="postprocess_project.sh"
print_step "Checking if there are any project-specific post processing steps"
if [[ -e ${POSTPROCESS_SCRIPT} ]]; then
  echo -e "Found ${POSTPROCESS_SCRIPT}. Running it..."
  ./${POSTPROCESS_SCRIPT}
  echo "Done"
fi

echo -e "\nDone creating project ${PROJECT_ID}!
Next steps, not done by this script, are:
1. Set the health check on the instance group. This can't be scripted yet!
   See note in this script. :(
2. Point the domain to the external IP ${EXTERNAL_IP_ADDRESS}
3. Select a region for DataStore at https://console.cloud.google.com/datastore/setup
4. Encrypt and upload app secrets (encrypt_and_upload_app_secrets.sh)
5. Upload the latest static content to the bucket with build_and_deploy_static_content.sh
6. Upload the latest docker image to the GKE cluster with build_and_upload_docker_image.sh
   (This depends on secrets from step 4 and index.html generated in step 5).
7. Deploy the image you just loaded in Kubernetes Engine -> Workloads -> portability-api -> Actions
   -> Rolling Update
8. (Optional) Enable IAP to whitelist only select users to view the app
"
