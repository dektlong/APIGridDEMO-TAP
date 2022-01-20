#!/usr/bin/env bash

source .config/config-values.env
PRIVATE_REPO=$(yq e .ootb_supply_chain_basic.registry.server .config/tap-values.yaml)
PRIVATE_REPO_USER=$(yq e .buildservice.kp_default_repository_username .config/tap-values.yaml)
PRIVATE_REPO_PASSWORD=$(yq e .buildservice.kp_default_repository_password .config/tap-values.yaml)

#init (assumes api-portal and api-gw are installed)
init() {

        echo "!!! currently only working on AKS due to SCGW issue. Hit any key to continue..."
        read
        #dekt4pets images
        frontend_image_location=$PRIVATE_REPO/$PRIVATE_REGISTRY_APP_REPO/$FRONTEND_TBS_IMAGE:$APP_VERSION
        backend_image_location=$PRIVATE_REPO/$PRIVATE_REGISTRY_APP_REPO/$BACKEND_TBS_IMAGE:$APP_VERSION

        export REGISTRY_PASSWORD=$PRIVATE_REPO_PASSWORD
        kp secret create private-registry-creds \
            --registry $PRIVATE_REPO \
            --registry-user $PRIVATE_REPO_USER \
            --namespace $DEMO_APPS_NS 
    
        kp image create $BACKEND_TBS_IMAGE -n $DEMO_APPS_NS \
        --tag $backend_image_location \
        --git $DEMO_APP_GIT_REPO  \
        --sub-path ./workloads/dekt4pets/backend \
        --git-revision main
       

        kp image save $FRONTEND_TBS_IMAGE -n $DEMO_APPS_NS \
        --tag $frontend_image_location \
        --git $DEMO_APP_GIT_REPO  \
        --sub-path ./workloads/dekt4pets/frontend \
        --git-revision main 

        #dekt4pets secrets
        kubectl create secret generic sso-secret --from-env-file=.config/sso-creds.txt -n $DEMO_APPS_NS
        kubectl create secret generic jwk-secret --from-env-file=.config/jwk-creds.txt -n $DEMO_APPS_NS
        kubectl create secret generic wavefront-secret --from-env-file=.config/wavefront-creds.txt -n $DEMO_APPS_NS

        #dev gateway
        kubectl apply -f workloads/dekt4pets/gateway/dekt4pets-gateway-dev.yaml -n $DEMO_APPS_NS

        #ingress rules
        scripts/ingress-handler.sh scgw

}

#create-backend 
create-backend() {

    echo
    echo "${bold}Deploy dekt4pets-backend (inner loop)${normal}"
    echo "------------------------------------------"
    echo
   
    echo
    echo "=========> 1. Commit code changes to $DEMO_APP_GIT_REPO"
    echo            
    
    touch dummy-commit.me

    git add .
    git commit -q -m "done backend inner-loop" dummy-commit.me
    git push

    echo
    echo "=========> 2. Apply development routes, mapping and micro-gateway"
    echo

    kubectl apply -f workloads/dekt4pets/backend/routes/dekt4pets-backend-mapping-dev.yaml -n $DEMO_APPS_NS
    kubectl apply -f workloads/dekt4pets/backend/routes/dekt4pets-backend-route-config.yaml -n $DEMO_APPS_NS
    #dekt4pets-dev gateway instances created as part of demo build to save time

    echo
    echo "=========> 3. Create backend app via src-to-img supply-chain"
    echo

    #kp image patch $BACKEND_TBS_IMAGE -n $DEMO_APPS_NS

    #wait-for-tbs $BACKEND_TBS_IMAGE $DEMO_APPS_NS

    echo
    echo "Starting to tail build logs ..."
    echo
    
    kp build logs $BACKEND_TBS_IMAGE -n $DEMO_APPS_NS
    
    kubectl apply -f workloads/dekt4pets/backend/dekt4pets-backend.yaml -n $DEMO_APPS_NS
}

#create-frontend 
create-frontend() {
	
    echo
    echo "=========> Create dekt4pets-frontend (inner loop) ..."
    echo "           1. Deploy app via src-to-img supply-chain"
    echo "           2. Apply development routes, mapping and micro-gateway"
    echo

    kp image patch $FRONTEND_TBS_IMAGE -n $DEMO_APPS_NS
    
	kustomize build workloads/dekt4pets/frontend | kubectl apply -f -

}

#patch-backend
patch-backend() {
    
    echo
    echo "=========> Commit code changes to $DEMO_APP_GIT_REPO  ..."
    echo
    
    commit-adopter-check-api

    wait-for-tbs $BACKEND_TBS_IMAGE $DEMO_APPS_NS

    echo
    echo "Starting to tail build logs ..."
    echo
    
    kp build logs $BACKEND_TBS_IMAGE -n $DEMO_APPS_NS
    
    echo
    echo "=========> Apply changes to backend app, service and routes ..."
    echo
    
    kubectl delete -f workloads/dekt4pets/backend/dekt4pets-backend.yaml -n $DEMO_APPS_NS
    kubectl apply -f workloads/dekt4pets/backend/dekt4pets-backend.yaml -n $DEMO_APPS_NS
    kubectl apply -f workloads/dekt4pets/backend/routes/dekt4pets-backend-route-config.yaml -n $DEMO_APPS_NS

}

#dekt4pets
dekt4pets() {

    echo
    echo "=========> Promote dekt4pets-backend to production (outer loop) ..."
    echo "           1. Deploy app via src-to-img supply-chain"
    echo "           2. Apply production routes, mapping and micro-gateway"
    echo
    kubectl apply -f workloads/dekt4pets/backend/routes/dekt4pets-backend-mapping.yaml -n $DEMO_APPS_NS

    echo
    echo "=========> Promote dekt4pets-frontend to production (outer loop) ..."
    echo "           1. Deploy app via src-to-img supply-chain"
    echo "           2. Apply production routes, mapping and micro-gateway"
    echo
    kubectl apply -f workloads/dekt4pets/frontend/routes/dekt4pets-frontend-mapping.yaml -n $DEMO_APPS_NS

    echo
    echo "=========> Create dekt4pets micro-gateway (w/ external traffic)..."
    echo
    kubectl apply -f workloads/dekt4pets/gateway/dekt4pets-gateway.yaml -n $DEMO_APPS_NS

}

#adopter-check-workload
adopter-check () {

    echo
    echo "=========> Apply adopter-check TAP workload and deploy via src-to-url supply-chain ..."
    echo

    tanzu apps workload apply adopter-check -f adopter-check-workload.yaml -y -n $DEMO_APPS_NS

    #tanzu apps workload tail adopter-check --since 10m --timestamp  -n dekt-apps

    tanzu apps workload get adopter-check -n dekt-apps

}

#commit-adopter-check-api
commit-adopter-check-api () {

    git commit -m "add check-adpoter api route" workloads/dekt4pets/backend/routes/dekt4pets-backend-route-config.yaml

    git commit -m "add check-adpoter function" workloads/dekt4pets/backend/src/main/java/io/spring/cloud/samples/animalrescue/backend/AnimalController.java

    git push
}

#cleanup
cleanup() {

    echo
    echo "=========> Remove all workloads..."
    echo

    kubectl delete -f workloads/dekt4pets/backend/routes/dekt4pets-backend-mapping-dev.yaml -n dekt-apps
    kubectl delete -f workloads/dekt4pets/backend/routes/dekt4pets-backend-route-config.yaml -n dekt-apps
    kubectl delete -f workloads/dekt4pets/backend/dekt4pets-backend.yaml -n dekt-apps
    kubectl delete -f workloads/dekt4pets/backend/dekt4pets-gateway.yaml -n dekt-apps

    kustomize build workloads/dekt4pets/frontend | kubectl delete -f -  
    
    #kustomize build workloads/dektFitness/kubernetes-manifests/ | kubectl delete -f -  

    tanzu apps workload delete adopter-check -y -n $DEMO_APPS_NS 

    rm dummy-commit.me

}

#wait4tbs
wait-for-tbs() {
    image_name=$1
    namespace=$2

    status=""
    printf "Waiting for tanzu build service to start building $image_name image in namespace $namespace"
    while [ "$status" == "" ]
    do
        printf "."
        status="$(kp image status $image_name -n $namespace | grep 'Building')" 
        sleep 1
    done
    echo
}

#usage
usage() {

    echo
	echo "Incorrect usage. Please specify one of the following:"
	echo
    echo "${bold}init${normal} - deploy the dekt4pets components"
    echo
    echo "${bold}describe${normal} - describe the dekt4pets api-grid configs"
    echo
    echo "${bold}backend${normal} - deploy the dekt4pets backend service and APIs"
    echo "          (use -u for update)"
    echo
    echo "${bold}frontend${normal} - deploy the dekt4pets frotend service and APIs"
    echo
    echo "${bold}dekt4pets${normal} - run end-to-end dekt4pets deployment to production"
    echo
    echo "${bold}adopter-check${normal} - deploy the adopter-check TAP workload using the default supply-chain"
    echo
    echo 
  	exit   
 
}

#describe-apigrid
describe-apigrid() {

    echo
    echo "${bold}Dekt4pets api-grid components${normal}"
    echo "-------------------------------------"
    echo
    echo
    echo "${bold}Workload Images${normal}"
    echo
    kp images list -n $DEMO_APPS_NS
    echo "${bold}API Routes${normal}"
    echo
    kubectl get SpringCloudGatewayRouteConfig -n $DEMO_APPS_NS 
    echo
    echo "${bold}API Mappings${normal}"
    echo
    kubectl get SpringCloudGatewayMapping -n $DEMO_APPS_NS 
    echo
    echo "${bold}API Gateways${normal}"
    echo
    
    echo
    echo "${bold}Ingress rules${normal}"
    kubectl get ingress --field-selector metadata.name=dekt4pets-ingress -n $DEMO_APPS_NS
    echo
}

#################### main #######################

bold=$(tput bold)
normal=$(tput sgr0)

case $1 in

init)
    init
    ;;
backend)
	if [ "$2" == "-u" ]
    then
        patch-backend
    else
        create-backend
    fi
    ;;
frontend)
	create-frontend
    ;;
dekt4pets)
    dekt4pets
    ;;
adopter-check)
	adopter-check
    ;;
describe)
    describe-apigrid
    ;;
cleanup)
    cleanup
    ;;
*)
  	usage
  	;;
esac
