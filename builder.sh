#!/usr/bin/env bash

#################### configs ################
    #clusters
    DEV_CLUSTER_NAME=$(yq .dev-cluster.name .config/demo-values.yaml)
    DEV_CLUSTER_PROVIDER=$(yq .dev-cluster.provider .config/demo-values.yaml)
    DEV_CLUSTER_NODES=$(yq .dev-cluster.nodes .config/demo-values.yaml)
    STAGE_CLUSTER_NAME=$(yq .stage-cluster.name .config/demo-values.yaml)
    STAGE_CLUSTER_PROVIDER=$(yq .stage-cluster.provider .config/demo-values.yaml)
    STAGE_CLUSTER_NODES=$(yq .stage-cluster.nodes .config/demo-values.yaml)
    PROD_CLUSTER_NAME=$(yq .prod-cluster.name .config/demo-values.yaml)
    PROD_CLUSTER_PROVIDER=$(yq .prod-cluster.provider .config/demo-values.yaml)
    PROD_CLUSTER_NODES=$(yq .prod-cluster.nodes .config/demo-values.yaml)
    VIEW_CLUSTER_NAME=$(yq .view-cluster.name .config/demo-values.yaml)
    VIEW_CLUSTER_PROVIDER=$(yq .view-cluster.provider .config/demo-values.yaml)
    VIEW_CLUSTER_NODES=$(yq .view-cluster.nodes .config/demo-values.yaml)
    BROWNFIELD_CLUSTER_NAME=$(yq .brownfield-cluster.name .config/demo-values.yaml)
    BROWNFIELD_CLUSTER_PROVIDER=$(yq .brownfield-cluster.provider .config/demo-values.yaml)
    BROWNFIELD_CLUSTER_NODES=$(yq .brownfield-cluster.nodes .config/demo-values.yaml)

    #image registry
    PRIVATE_REPO_SERVER=$(yq .ootb_supply_chain_basic.registry.server .config/tap-iterate.yaml)
    PRIVATE_REPO_USER=$(yq .buildservice.kp_default_repository_username .config/tap-iterate.yaml)
    PRIVATE_REPO_PASSWORD=$(yq .buildservice.kp_default_repository_password .config/tap-iterate.yaml)
    SYSTEM_REPO=$(yq .tap.systemRepo .config/demo-values.yaml)
    #tap
    TANZU_NETWORK_USER=$(yq .buildservice.tanzunet_username .config/tap-iterate.yaml)
    TANZU_NETWORK_PASSWORD=$(yq .buildservice.tanzunet_password .config/tap-iterate.yaml)
    TAP_VERSION=$(yq .tap.version .config/demo-values.yaml)
    #apps-namespaces
    DEV_NAMESPACE=$(yq .apps-namespaces.dev .config/demo-values.yaml)
    TEAM_NAMESPACE=$(yq .apps-namespaces.team .config/demo-values.yaml)
    STAGEPROD_NAMESPACE=$(yq .apps-namespaces.stageProd .config/demo-values.yaml)
    #domains
    SYSTEM_SUB_DOMAIN=$(yq .tap_gui.ingressDomain .config/tap-view.yaml | cut -d'.' -f 1)
    DEV_SUB_DOMAIN=$(yq .cnrs.domain_name .config/tap-iterate.yaml | cut -d'.' -f 1)
    RUN_SUB_DOMAIN=$(yq .cnrs.domain_name .config/tap-run.yaml | cut -d'.' -f 1)
    #misc        
    GW_INSTALL_DIR=$(yq .apis.scgwInstallDirectory .config/demo-values.yaml)

#################### functions ################

    #install-view-cluster
    install-view-cluster() {

        scripts/dektecho.sh info "Installing demo components for $VIEW_CLUSTER_NAME cluster"

        kubectl config use-context $VIEW_CLUSTER_NAME

        scripts/tanzu-handler.sh add-carvel-tools
        
        add-tap-package "tap-view.yaml"
        
        scripts/dektecho.sh status "Adding custom accelerators"
        kustomize build accelerators | kubectl apply -f -

        scripts/ingress-handler.sh update-tap-dns $SYSTEM_SUB_DOMAIN
    }

    #install-dev-cluster
    install-dev-cluster() {

        scripts/dektecho.sh info "Installing demo components for $DEV_CLUSTER_NAME cluster"

        kubectl config use-context $DEV_CLUSTER_NAME

        scripts/tanzu-handler.sh add-carvel-tools

        setup-apps-namespace $DEV_NAMESPACE
        setup-apps-namespace $TEAM_NAMESPACE
        
        add-tap-package "tap-iterate.yaml"

        scripts/dektecho.sh status "Adding dekt-dev custom supply chain"
        kubectl apply -f .config/disable-scale2zero.yaml
        kubectl apply -f .config/dekt-dev-supplychain.yaml
        kubectl apply -f .config/tekton-pipeline.yaml -n $DEV_NAMESPACE
        kubectl apply -f .config/tekton-pipeline.yaml -n $TEAM_NAMESPACE

        provision-data-services $TEAM_NAMESPACE "reading-rabbitmq-dev.yaml"

        scripts/ingress-handler.sh update-tap-dns $DEV_SUB_DOMAIN
    }

    #install-stage-cluster
    install-stage-cluster() {

        scripts/dektecho.sh info "Installing demo components for $STAGE_CLUSTER_NAME cluster"

        kubectl config use-context $STAGE_CLUSTER_NAME

        scripts/tanzu-handler.sh add-carvel-tools
    
        setup-apps-namespace $STAGEPROD_NAMESPACE
        
        add-tap-package "tap-build.yaml"

        scripts/dektecho.sh status "Adding dekt-build custom supply chain"
        kubectl apply -f .config/dekt-build-supplychain.yaml
        kubectl apply -f .config/tekton-pipeline.yaml -n $STAGEPROD_NAMESPACE
        kubectl apply -f .config/scan-policy.yaml -n $STAGEPROD_NAMESPACE

        provision-data-services $STAGEPROD_NAMESPACE "reading-rabbitmq-prod.yaml"

        #configure-multi-cluster-scanning-store 
    }
    
    #install-prod-cluster
    install-prod-cluster() {

        scripts/dektecho.sh info "Installing demo components for $PROD_CLUSTER_NAME cluster"

        kubectl config use-context $PROD_CLUSTER_NAME

        scripts/tanzu-handler.sh add-carvel-tools
        
        setup-apps-namespace $STAGEPROD_NAMESPACE
        
        add-tap-package "tap-run.yaml"

        kubectl apply -f .config/disable-scale2zero.yaml

        provision-data-services $STAGEPROD_NAMESPACE "reading-rabbitmq-prod.yaml"

        scripts/ingress-handler.sh update-tap-dns $RUN_SUB_DOMAIN

    }

    #add-tap-package
    add-tap-package() {

        tap_values_file_name=$1

        scripts/dektecho.sh status "Installing TAP on $(kubectl config current-context) cluster with $tap_values_file_name configs"

        kubectl create ns tap-install
       
        tanzu secret registry add tap-registry \
            --username ${TANZU_NETWORK_USER} --password ${TANZU_NETWORK_PASSWORD} \
            --server "registry.tanzu.vmware.com" \
            --export-to-all-namespaces --yes --namespace tap-install

        tanzu package repository add tanzu-tap-repository \
            --url registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:$TAP_VERSION \
            --namespace tap-install

        tanzu package install tap -p tap.tanzu.vmware.com -v $TAP_VERSION \
            --values-file .config/$tap_values_file_name \
            --namespace tap-install
    }

    #setup-apps-namespace
    setup-apps-namespace() {
        
        appsNamespace=$1

        scripts/dektecho.sh status "Setup $appsNamespace namespace on $(kubectl config current-context) cluster"

        kubectl create ns $appsNamespace
        tanzu secret registry add registry-credentials \
            --server $PRIVATE_REPO_SERVER \
            --username $PRIVATE_REPO_USER \
            --password $PRIVATE_REPO_PASSWORD \
            --namespace $appsNamespace    

        kubectl apply -f .config/supplychain-rbac.yaml -n $appsNamespace
    }

    #add-data-services
    provision-data-services() {

        appsNamespace=$1
        dataInstanceFile=$2

        scripts/dektecho.sh status "Provision rabbitMQ instance in $appsNamespace namespace with $dataInstanceFile configs"

        kapp -y deploy --app rmq-operator --file https://github.com/rabbitmq/cluster-operator/releases/download/v1.9.0/cluster-operator.yml
        kubectl apply -f .config/rabbitmq-cluster-config.yaml -n $appsNamespace
        kubectl apply -f .config/$dataInstanceFile -n $appsNamespace
    }
    
    #configure-multi-cluster-scanning-store
    configure-multi-cluster-scanning-store() {

        scripts/dektecho.sh status "Configuring multi-cluster scanning Store"
        
        kubectl config use-context $VIEW_CLUSTER_NAME
        export storeCert=$(kubectl get secret -n metadata-store ingress-cert -o json | jq -r ".data.\"ca.crt\"")
        yq '.data."ca.crt"= env(storeCert)' .config/store-ca.yaml -i
        storeToken=$(kubectl get secrets -n metadata-store -o jsonpath="{.items[?(@.metadata.annotations['kubernetes\.io/service-account\.name']=='metadata-store-read-write-client')].data.token}" | base64 -d)
        
        kubectl config use-context $STAGE_CLUSTER_NAME
        kubectl create ns metadata-store-secrets
        kubectl apply -f .config/store-ca.yaml
        kubectl create secret generic store-auth-token --from-literal=auth_token=$storeToken -n metadata-store-secrets
        kubectl apply -f .config/store-secrets-export.yaml
    }
    #update-multi-cluster-views
    update-multi-cluster-views() {

        scripts/dektecho.sh status "Configure TAP Workloads GUI plugin to support multi-clusters"
          
        kubectl config use-context $DEV_CLUSTER_NAME
        kubectl apply -f .config/tap-gui-viewer-sa-rbac.yaml
        export devClusterUrl=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
        export devClusterToken=$(kubectl -n tap-gui get secret $(kubectl -n tap-gui get sa tap-gui-viewer -o=json \
        | jq -r '.secrets[0].name') -o=json \
        | jq -r '.data["token"]' \
        | base64 --decode)

        yq '.tap_gui.app_config.kubernetes.clusterLocatorMethods.[0].clusters.[0].url = env(devClusterUrl)' .config/tap-view.yaml -i
        yq '.tap_gui.app_config.kubernetes.clusterLocatorMethods.[0].clusters.[0].serviceAccountToken = env(devClusterToken)' .config/tap-view.yaml -i

        kubectl config use-context $STAGE_CLUSTER_NAME
        kubectl apply -f .config/tap-gui-viewer-sa-rbac.yaml
        export stageClusterUrl=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
        export stageClusterToken=$(kubectl -n tap-gui get secret $(kubectl -n tap-gui get sa tap-gui-viewer -o=json \
        | jq -r '.secrets[0].name') -o=json \
        | jq -r '.data["token"]' \
        | base64 --decode)

        yq '.tap_gui.app_config.kubernetes.clusterLocatorMethods.[0].clusters.[1].url = env(stageClusterUrl)' .config/tap-view.yaml -i
        yq '.tap_gui.app_config.kubernetes.clusterLocatorMethods.[0].clusters.[1].serviceAccountToken = env(stageClusterToken)' .config/tap-view.yaml -i


        kubectl config use-context $PROD_CLUSTER_NAME
        kubectl apply -f .config/tap-gui-viewer-sa-rbac.yaml
        export prodClusterUrl=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
        export prodClusterToken=$(kubectl -n tap-gui get secret $(kubectl -n tap-gui get sa tap-gui-viewer -o=json \
        | jq -r '.secrets[0].name') -o=json \
        | jq -r '.data["token"]' \
        | base64 --decode)

        yq '.tap_gui.app_config.kubernetes.clusterLocatorMethods.[0].clusters.[2].url = env(prodClusterUrl)' .config/tap-view.yaml -i
        yq '.tap_gui.app_config.kubernetes.clusterLocatorMethods.[0].clusters.[2].serviceAccountToken = env(prodClusterToken)' .config/tap-view.yaml -i

        kubectl config use-context $VIEW_CLUSTER_NAME
        tanzu package installed update tap --package-name tap.tanzu.vmware.com --version $TAP_VERSION -n tap-install -f .config/tap-view.yaml

    } 
 
    #add-brownfield-apis
    add-brownfield-apis () {
        
        brownfield_apis_ns="brownfield-apis"

        scripts/dektecho.sh info "Installing brownfield APIs 'provider' components on $BROWNFIELD_CLUSTER_NAME cluster"
        kubectl config use-context $BROWNFIELD_CLUSTER_NAME
        kubectl create ns scgw-system
        kubectl create secret docker-registry spring-cloud-gateway-image-pull-secret \
            --docker-server=$PRIVATE_REPO_SERVER \
            --docker-username=$PRIVATE_REPO_USER \
            --docker-password=$PRIVATE_REPO_PASSWORD \
            --namespace scgw-system
        #relocate-gw-images
        $GW_INSTALL_DIR/scripts/install-spring-cloud-gateway.sh --namespace scgw-system
        kubectl create ns $brownfield_apis_ns
        kustomize build brownfield-apis | kubectl apply -f -

        scripts/dektecho.sh info "Installing brownfield APIs 'consumer' components on $DEV_CLUSTER_NAME cluster"
        kubectl config use-context $DEV_CLUSTER_NAME
        kubectl create ns $brownfield_apis_ns
        kubectl create service clusterip sentiment-api --tcp=80:80 -n $brownfield_apis_ns
        kubectl create service clusterip datacheck-api --tcp=80:80 -n $brownfield_apis_ns

        scripts/dektecho.sh info "Installing brownfield APIs 'consumer' components on $STAGE_CLUSTER_NAME cluster"
        kubectl config use-context $STAGE_CLUSTER_NAME
        kubectl create ns $brownfield_apis_ns
        kubectl create service clusterip sentiment-api --tcp=80:80 -n $brownfield_apis_ns
        kubectl create service clusterip datacheck-api --tcp=80:80 -n $brownfield_apis_ns

        scripts/dektecho.sh info "Installing brownfield APIs 'consumer' components on $PROD_CLUSTER_NAME cluster"
        kubectl config use-context $PROD_CLUSTER_NAME
        kubectl create ns $brownfield_apis_ns
        kubectl create service clusterip sentiment-api --tcp=80:80 -n $brownfield_apis_ns
        kubectl create service clusterip datacheck-api --tcp=80:80 -n $brownfield_apis_ns

    }

    #relocate-images
    relocate-gw-images() {

        echo "Make sure docker deamon is running..."
        read
        
        docker login $PRIVATE_REPO_SERVER -u $PRIVATE_REPO_USER -p $PRIVATE_REPO_PASSWORD
        
        $GW_INSTALL_DIR/scripts/relocate-images.sh $PRIVATE_REPO_SERVER/$SYSTEM_REPO
    }

    #relocate-tds-images
    relocate-tds-images() {

        #docker login $PRIVATE_REPO_SERVER -u $PRIVATE_REPO_USER -p $PRIVATE_REPO_PASSWORD
        #docker login registry.tanzu.vmware.com -u $TANZU_NETWORK_USER -p $TANZU_NETWORK_PASSWORD
        
        #imgpkg copy -b registry.tanzu.vmware.com/packages-for-vmware-tanzu-data-services/tds-packages:1.0.0 \
        #    --to-repo $PRIVATE_REPO_SERVER/$SYSTEM_REPO/tds-packages

        tanzu package repository add tanzu-data-services-repository --url $PRIVATE_REPO_SERVER/$SYSTEM_REPO/tds-packages:1.0.0 -n tap-install
    }

    #relocate-tap-images
    relocate-tap-images() {

        scripts/dektecho.sh err "Make sure docker deamon is running..."
        read
        
        docker login $PRIVATE_REPO_SERVER -u $PRIVATE_REPO_USER -p $PRIVATE_REPO_PASSWORD

        docker login registry.tanzu.vmware.com -u $TANZU_NETWORK_USER -p $TANZU_NETWORK_PASSWORD
        
        export INSTALL_REGISTRY_USERNAME=$PRIVATE_REPO_USER
        export INSTALL_REGISTRY_PASSWORD=$PRIVATE_REPO_PASSWORD
        export INSTALL_REGISTRY_HOSTNAME=$PRIVATE_REPO_SERVER
        export TAP_VERSION=$TAP_VERSION

        imgpkg copy -b registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:$TAP_VERSION \
            --to-repo ${INSTALL_REGISTRY_HOSTNAME}/$SYSTEM_REPO/tap-packages

    }
    
    #install-gui-dev
    install-gui-dev() {

        kubectl apply -f .config/tap-gui-dev-package.yaml

        export INSTALL_REGISTRY_HOSTNAME=dev.registry.tanzu.vmware.com
        export INSTALL_REGISTRY_USERNAME=$TANZU_NETWORK_USER
        export INSTALL_REGISTRY_PASSWORD=$TANZU_NETWORK_PASSWORD

        tanzu secret registry add dev-registry --username ${INSTALL_REGISTRY_USERNAME} --password ${INSTALL_REGISTRY_PASSWORD} --server ${INSTALL_REGISTRY_HOSTNAME} --export-to-all-namespaces --yes --namespace tap-install

        tanzu package install tap-gui -p tap-gui.tanzu.vmware.com -v 1.1.0-build.1 --values-file .config/tap-gui-values.yaml -n tap-install

        #scripts/ingress-handler.sh gui-dev
        kubectl port-forward service/server 7000 -n tap-gui

        
       
    }

    #delete-tap
    delete-tap() {

        kubectl config use-context $1

        tanzu package installed delete tap -n tap-install -y

        kubectl delete ns tap-install
        kubectl delete ns dekt-apps
        kubectl delete ns mydev
        kubectl delete ns myteam

    }
    
    #incorrect usage
    incorrect-usage() {
        
        scripts/dektecho.sh err "Incorrect usage. Please specify one of the following: "
        
        echo "  create-clusters"
        echo
        echo "  install-demo"
        echo       
        echo "  uninstall-demo"
        echo
        echo "  delete-all"
        echo
        echo "  relocate-tap-images"
        echo
        echo "  runme [ function-name ]"
        echo
        exit
    }

    #delete-clusters
    delete-clusters() {

        scripts/k8s-handler.sh delete $VIEW_CLUSTER_PROVIDER $VIEW_CLUSTER_NAME
        scripts/k8s-handler.sh delete $DEV_CLUSTER_PROVIDER $DEV_CLUSTER_NAME
        scripts/k8s-handler.sh delete $STAGE_CLUSTER_PROVIDER $STAGE_CLUSTER_NAME
        scripts/k8s-handler.sh delete $PROD_CLUSTER_PROVIDER $PROD_CLUSTER_NAME
        scripts/k8s-handler.sh delete $BROWNFIELD_CLUSTER_PROVIDER $BROWNFIELD_CLUSTER_NAME
    }

    #remove-tap
    remove-tap() {
        delete-tap "dekt-view"
        delete-tap "dekt-dev"
        delete-tap "dekt-stage"
        delete-tap "dekt-prod"
    }

#################### main ##########################

case $1 in
create-clusters)
    scripts/k8s-handler.sh create $VIEW_CLUSTER_PROVIDER $VIEW_CLUSTER_NAME $VIEW_CLUSTER_NODES
    scripts/k8s-handler.sh create $DEV_CLUSTER_PROVIDER $DEV_CLUSTER_NAME $DEV_CLUSTER_NODES
    scripts/k8s-handler.sh create $STAGE_CLUSTER_PROVIDER $STAGE_CLUSTER_NAME $STAGE_CLUSTER_NODES  
    scripts/k8s-handler.sh create $PROD_CLUSTER_PROVIDER $PROD_CLUSTER_NAME $PROD_CLUSTER_NODES
    scripts/k8s-handler.sh create $BROWNFIELD_CLUSTER_PROVIDER $BROWNFIELD_CLUSTER_NAME $BROWNFIELD_CLUSTER_NODES
    ;;
install-demo)    
    install-view-cluster
    install-dev-cluster
    install-stage-cluster
    install-prod-cluster
    add-brownfield-apis
    update-multi-cluster-views
    ;;
delete-all)
    scripts/dektecho.sh prompt  "Are you sure you want to delete all clusters?" && [ $? -eq 0 ] || exit
    ./dekt-DevSecOps.sh cleanup-helper
    delete-clusters
    rm -f /Users/dekt/.kube/config
    ;;
uninstall-demo)
    scripts/dektecho.sh prompt  "Are you sure you want to uninstall all demo components?" && [ $? -eq 0 ] || exit
    ./dekt-DevSecOps.sh cleanup-helper
    remove-tap
    ;;
relocate-tap-images)
    relocate-tap-images
    ;;
inner-loop)
    scripts/k8s-handler.sh create $VIEW_CLUSTER_PROVIDER $VIEW_CLUSTER_NAME $VIEW_CLUSTER_NODES
    scripts/k8s-handler.sh create $DEV_CLUSTER_PROVIDER $DEV_CLUSTER_NAME $DEV_CLUSTER_NODES
    install-view-cluster
    install-dev-cluster
    update-multi-cluster-views
    ;;
runme)
    $2 $3 $4
    ;;
*)
    incorrect-usage
    ;;
esac