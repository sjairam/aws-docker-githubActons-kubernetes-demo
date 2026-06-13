#!/bin/bash

# AWS variables
AWS_PROFILE=default
AWS_REGION=us-east-1

# project variables
PROJECT_NAME=aws-docker-github-kubernetes

WEBSITE_PORT=3000

# the directory containing the script file
export dir="$(cd "$(dirname "$0")"; pwd)"

echo ' dir '+ $dir
cd "$dir"

log()   { echo -e " $1 "; }        # $1 uppercase background white
info()  { echo -e " $1 "; }      # $1 uppercase background green
warn()  { echo -e " $1 "; }
error() { echo -e " $1 "; }

#log()   { echo -e "\e[30;47m ${1^^} \e[0m ${@:2}"; }        # $1 uppercase background white
#info()  { echo -e "\e[48;5;28m ${1^^} \e[0m ${@:2}"; }      # $1 uppercase background green
#warn()  { echo -e "\e[48;5;202m ${1^^} \e[0m ${@:2}" >&2; } # $1 uppercase background orange
#error() { echo -e "\e[48;5;196m ${1^^} \e[0m ${@:2}" >&2; } # $1 uppercase background red

######################
## Create EKS Cluster
######################
# create the EKS cluster
cluster-create() {
    # check if cluster already exists (return something if the cluster exists, otherwise return nothing)
    local exists=$(aws eks describe-cluster \
        --name $PROJECT_NAME \
        --profile $AWS_PROFILE \
        --region $AWS_REGION \
        2>/dev/null)
        
    [[ -n "$exists" ]] && { error abort cluster $PROJECT_NAME already exists; return; }
    
    # create a cluster named $PROJECT_NAME
    log 'create eks cluster' + $PROJECT_NAME

    eksctl create cluster \
        --name $PROJECT_NAME \
        --region $AWS_REGION \
        --managed \
        --node-type t2.micro \
        --nodes 1 \
        --profile $AWS_PROFILE
}

############################
## CReate EKS Cluster Config
############################

# create kubectl EKS configuration
cluster-create-config() {
    log 'create kubeconfig.yaml'
    CONTEXT=$(kubectl config current-context)
    log 'context '+$CONTEXT
    kubectl config view --context=$CONTEXT --minify > kubeconfig.yaml

    log '--> inject certificate'
    # yq tips: https://mikefarah.gitbook.io/yq/usage/path-expressions#with-prefixes
    CERTIFICATE=$(yq read $HOME/.kube/config "clusters.(name==$PROJECT_NAME*).cluster.certificate-authority-data")
    log ' certificate '+$CERTIFICATE
    yq write --inplace kubeconfig.yaml 'clusters[0].cluster.certificate-authority-data' $CERTIFICATE

    log ' delete env values'
    yq delete --inplace kubeconfig.yaml 'users[0].user.exec.env'

    log ' create KUBECONFIG file'
    # SANJAY:  Replace base64 --wrap with --b 0
    cat kubeconfig.yaml | base64 --b 0 > KUBECONFIG

    log ' configmap get configmap aws-auth file'
    kubectl -n kube-system get configmap aws-auth -o yaml > aws-auth-configmap.yaml

    # root account id
    local ACCOUNT_ID=$(aws sts get-caller-identity \
        --query 'Account' \
        --profile $AWS_PROFILE \
        --output text)

    warn warn 'inject the lines below in aws-auth-configmap.yaml'
    echo "mapUsers: |
    - userarn: arn:aws:iam::$ACCOUNT_ID:user/$PROJECT_NAME
      username: $PROJECT_NAME
      groups:
        - system:masters"
}

#######################
## Cluster Apply Config
#######################

# apply kubectl EKS configuration
cluster-apply-config() {
    # check if data.mapUsers is configured (return something if data.mapUsers is configured, otherwise return nothing)
    local exists=$(yq read aws-auth-configmap.yaml data.mapUsers)
    [[ -z "$exists" ]] && { error abort data.mapUsers not configured in aws-auth-configmap.yaml; return; }

    log '--> apply aws-auth-configmap.yaml'
    kubectl -n kube-system apply -f aws-auth-configmap.yaml

    log ' test kubectl get ns'
    source "$dir/.env"
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    kubectl --kubeconfig kubeconfig.yaml get ns
}

######################
## Delete EKS Cluster
######################

# delete the EKS cluster
cluster-delete() {
    eksctl delete cluster \
        --name $PROJECT_NAME \
        --region $AWS_REGION \
        --profile $AWS_PROFILE
}


###############
## Create Env
###############

create-env() {
    # log install site npm modules
    cd "$dir/site"
    npm install

    [[ -f "$dir/.env" ]] && { log skip .env file already exists; return; }
    info create .env file

    # check if user already exists (return something if user exists, otherwise return nothing)
    local exists=$(aws iam list-user-policies \
        --user-name $PROJECT_NAME \
        --profile $AWS_PROFILE \
        2>/dev/null)
        
    [[ -n "$exists" ]] && { error abort user $PROJECT_NAME already exists; return; }

    # create a user named $PROJECT_NAME
    log 'create iam user '+$PROJECT_NAME
    aws iam create-user \
        --user-name $PROJECT_NAME \
        --profile $AWS_PROFILE \
        1>/dev/null

    aws iam attach-user-policy \
        --user-name $PROJECT_NAME \
        --policy-arn arn:aws:iam::aws:policy/PowerUserAccess \
        --profile $AWS_PROFILE

    local key=$(aws iam create-access-key \
        --user-name $PROJECT_NAME \
        --query 'AccessKey.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey}' \
        --profile $AWS_PROFILE \
        2>/dev/null)

    local AWS_ACCESS_KEY_ID=$(echo "$key" | jq '.AccessKeyId' --raw-output)
    log 'AWS_ACCESS_KEY_ID' + $AWS_ACCESS_KEY_ID
    
    local AWS_SECRET_ACCESS_KEY=$(echo "$key" | jq '.SecretAccessKey' --raw-output)
    log 'AWS_SECRET_ACCESS_KEY' + $AWS_SECRET_ACCESS_KEY

    # create ECR repository
    local repo=$(aws ecr describe-repositories \
        --repository-names $PROJECT_NAME \
        --region $AWS_REGION \
        --profile $AWS_PROFILE \
        2>/dev/null)
    if [[ -z "$repo" ]]
    then
        log 'ecr create-repository'+ $PROJECT_NAME
        local ECR_REPOSITORY=$(aws ecr create-repository \
            --repository-name $PROJECT_NAME \
            --region $AWS_REGION \
            --profile $AWS_PROFILE \
            --query 'repository.repositoryUri' \
            --output text)
        log 'ECR_REPOSITORY '+ $ECR_REPOSITORY
    fi

    # envsubst tips : https://unix.stackexchange.com/a/294400
    # create .env file
    cd "$dir"
    # export variables for envsubst
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export ECR_REPOSITORY
    envsubst < .env.tmpl > .env

    info created file .env
}

########### 
## EKSCTL
###########
# install eksctl if missing (no update)
install-eksctl() {
    if [[ -z $(which eksctl) ]]
    then
        log 'install eksctl'
        warn warn sudo is required
        sudo wget -q -O - https://api.github.com/repos/weaveworks/eksctl/releases \
            | jq --raw-output 'map( select(.prerelease==false) | .assets[].browser_download_url ) | .[]' \
            | grep inux \
            | head -n 1 \
            | wget -q --show-progress -i - -O - \
            | sudo tar -xz -C /usr/local/bin

        # bash completion
        [[ -z $(grep eksctl_init_completion ~/.bash_completion 2>/dev/null) ]] \
            && eksctl completion bash >> ~/.bash_completion
    else
        log 'skip eksctl already installed'
    fi
}

###########
## KUBECTL 
###########
# install kubectl if missing (no update)
install-kubectl() {
    if [[ -z $(which kubectl) ]]
    then
        log 'install eksctl'
        warn warn sudo is required
        local VERSION=$(curl --silent https://storage.googleapis.com/kubernetes-release/release/stable.txt)
        cd /usr/local/bin
        sudo curl https://storage.googleapis.com/kubernetes-release/release/$VERSION/bin/linux/amd64/kubectl \
            --progress-bar \
            --location \
            --remote-name
        sudo chmod +x kubectl
    else
        log 'skip kubectl already installed'
    fi
}

###########
## yq
###########
# install yq if missing (no update)
install-yq() {
    if [[ -z $(which yq) ]]
    then
        log 'install yq'
        warn warn sudo is required
        cd /usr/local/bin
        sudo curl "https://github.com/mikefarah/yq/releases/download/3.4.1/yq_linux_amd64" \
            --progress-bar \
            --location \
            --output yq
        sudo chmod +x yq
    else
        log 'skip yq already installed'
    fi
}

# install eksctl + kubectl + yq, create aws user + ecr repository
setup() {
    log setup 
    install-eksctl
    install-kubectl
    install-yq
    create-env
}

###########
## TEST
###########

# run tests (by calling npm script directly)
test() { 
    cd "$dir/site"
    npm test
}

under() {
    local arg=$1
    shift
    echo -e " ${arg} "
    echo
}

usage() {
    under usage 'call the Makefile directly: make dev
      or invoke this file directly: ./make.sh dev'
}


clear
sleep 5
echo '-- >Starting '

# if `$1` is a function, execute it. Otherwise, print usage
# compgen -A 'function' list all declared functions
# https://stackoverflow.com/a/2627461
FUNC=$(compgen -A 'function' | grep $1)
[[ -n $FUNC ]] && { info execute $1; eval $1; } || usage;
exit 0

