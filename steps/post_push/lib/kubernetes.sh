ds_check_dns() {
	if [ "$1" = "" ]; then
		error "post-push: kubernetes: ingress-nginx: Too few arguments given to ds_check_dns"
	fi

	# NSLOOKUP_COMMAND="nslookup -type=a $1 8.8.8.8 | grep -E \"Address: [[:digit:]].*$\" | awk '{print \$2}'"
	# debug "$NSLOOKUP_COMMAND"
	ADDR=$(nslookup -type=a $1 8.8.8.8 | grep -E "Address: [[:digit:]].*$" | awk '{print $2}')
	if [ "$ADDR" = "" ]; then
		error "No DNS found for $1. Please configure DNS for $1 before using it for deployment"
	else
		info "Queried DNS for $1: $ADDR"
	fi
}

ds_kube_ingress_nginx() {
	if [ "$1" = "" ] || [ "$2" = "" ] || [ "$3" = "" ] || [ "$4" = "" ]; then
		error "post-push: kubernetes: ingress-nginx: Too few arguments given to ds_kube_ingress_nginx"
	fi

	ds_check_dns "$1"

	INGRESS_EXISTS=$(kubectl get ingress $KUBERNETES_INGRESS | grep "$KUBERNETES_INGRESS" | awk '{print $1}' | head -n1)
	debug $INGRESS_EXISTS

	if [ "$INGRESS_EXISTS" = "" ]; then
		error "Specified ingress $KUBERNETES_INGRESS not found on $KUBERNETES_CLUSTER"
	fi

	HOST_EXISTS=$(kubectl get ingress $KUBERNETES_INGRESS -o yaml | grep -E "\- host:.*$" | grep "$1" | awk '{print $3}')
	debug $HOST_EXISTS

	if [ "$HOST_EXISTS" != "" ]; then
		info "Host $1 already configured in $KUBERNETES_INGRESS. Skipping patch"
		return
	fi

	HOST_EXISTS_NON_ING=$(kubectl get ingress -o yaml | grep -E "\- host:.*$" | grep "$1" | awk '{print $3}')
	if [ "$HOST_EXISTS_NON_ING" != "" ] && [ "$HOST_EXISTS_NON_ING" != "$KUBERNETES_INGRESS" ]; then
		error "Host $1 already configured under $HOST_EXISTS_NON_ING"
	fi

	TIMESTAMP=$(date '+%s')
	if [ "$KUBERNETES_TLS" = "true" ]; then
		if [ "$KUBERNETES_TLS_SECRET" = "" ]; then
			KUBERNETES_TLS_SECRET=$(echo "finksec-$1" | sed "s/\./\-/g")
			warning "No KUBERNETES_TLS_SECRET var set, using autogenerated tls secret: $KUBERNETES_TLS_SECRET"
		fi

		INGRESS_PATCH=$(cat <<-END
[
    {
        "op" : "add" ,
        "path" : "/spec/rules/-" ,
        "value" : {
            "host": "$1",
            "http": {
                "paths": [
                    {
                        "backend": {
                            "service": {
                                "name": "$2",
                                "port": {
                                    "number": $3
                                }
                            }
                        },
                        "pathType": "ImplementationSpecific"
                    }
                ]
            }
        }
    },
	{
        "op" : "add" ,
        "path" : "/spec/tls/-" ,
        "value" : {
            "hosts": [
                "$1"
            ],
            "secretName": $KUBERNETES_TLS_SECRET
        }
    }
]
END
		)
	else
		INGRESS_PATCH=$(cat <<-END
[
    {
        "op" : "add" ,
        "path" : "/spec/rules/-" ,
        "value" : {
            "host": "$1",
            "http": {
                "paths": [
                    {
                        "backend": {
                            "serviceName": "$2",
                            "servicePort": $3
                        }
                    }
                ]
            }
        }
    }
]
END
		)
	fi

	INGRESS_PATCH_FILE="$KUBERNETES_HOME/ingress-patch-$TIMESTAMP.json"
	printf "$INGRESS_PATCH" > "$INGRESS_PATCH_FILE"

	ds_debug_cat "$INGRESS_PATCH_FILE"
	# yamllint "$KUBERNETES_NGINX_CONFIG"

	infof "Applying ingress patch for $1 to $KUBERNETES_INGRESS ... "
	kubectl patch ingress "$KUBERNETES_INGRESS" --namespace=$4 --type json --patch "$(cat $INGRESS_PATCH_FILE)"
	success "done"
	rm -f "$INGRESS_PATCH_FILE"
}

ds_post_push() {
	if [ "$1" = "" ]; then
		error "post-push: kubernetes: Too few arguments given to ds_post_push"
	fi

	cd "$1"
	if [ "$KUBERNETES_CLUSTER" = "" ]; then
		error "post-push: kubernetes: no KUBERNETES_CLUSTER value set"
	fi

	if [ "$KUBERNETES_CLUSTER_CONFIG" = "" ]; then
		KUBERNETES_CLUSTER_CONFIG="$KUBERNETES_HOME/$KUBERNETES_CLUSTER.yaml"
	fi

	export KUBECONFIG="$KUBERNETES_CLUSTER_CONFIG"
	ds_debug_exec "kubectl version --client"

	TAG=$(grep 'image:' docker-compose.yml | awk '{print $2}')

	if [ "$TAG" = "" ]; then
		error "post-push: kubernetes: Failed to look up tag in docker-compose.yml"
	fi

	SRV_NAME=$(echo $SERVICE_NAME | cut -d"." -f1)
	KUBE_SERVICE="$SRV_NAME-$PROJECT_ENVIRONMENT"

	DOCKER_IMAGE="$TAG"
	DOCKER_IMAGE_SED="$TAG"
	SLASH_CHECK=$(echo $TAG | grep '/' | wc -l)
	if [ $SLASH_CHECK -gt 0 ]; then
		DOCKER_IMAGE_SED=$(echo $TAG | sed -e 's/\//\\\//g')
	fi
	if [ "$DOCKER_REGISTRY" != "" ]; then
		DOCKER_HOST=$(echo "$DOCKER_REGISTRY" | awk -F / '{print $3}')
		DOCKER_IMAGE="$DOCKER_HOST/$TAG"
		DOCKER_IMAGE_SED="$DOCKER_HOST\\/$TAG"
	fi

	if [ "$KUBERNETES_NAMESPACE" = "" ]; then
		KUBERNETES_NAMESPACE="default"
	fi

	EXISTING_SERVICE=$(kubectl get services | grep "$KUBE_SERVICE" | wc -l)
	if [ $EXISTING_SERVICE -eq 0 ]; then
		KUBE_SERVICE_CFG="$1/../repo/$DS_DIR/environments/$PROJECT_ENVIRONMENT/kubernetes/service.yaml"

		if [ ! -f "$KUBE_SERVICE_CFG" ]; then
			warning "post-push: kubernetes: No service config found at $KUBE_SERVICE_CFG. Generating from template"
			# if [ "$DOCKER_REGISTRY" = "" ]; then
			# 	error "post-push: kubernetes: Auto k8s service generation currently depends on DOCKER_REGISTRY being set"
			# fi

			KUBE_MANIFESTS_DIR="$1/kube-manifests"
			mkdir -p "$KUBE_MANIFESTS_DIR"
			cp "$DEPLOY_SCRIPTS_DIR/steps/post_push/lib/kubernetes-resources/service.yaml" "$KUBE_MANIFESTS_DIR"
			KUBE_SVC_FILE="$KUBE_MANIFESTS_DIR/service.yaml"

			debug "$KUBE_SVC_FILE"

			sed -i "s/name:.*$/name: $KUBE_SERVICE/g" "$KUBE_SVC_FILE"
			sed -i "s/app:.*$/app: $KUBE_SERVICE/g" "$KUBE_SVC_FILE"
			debug "s/image:.*$/image: $DOCKER_IMAGE_SED/g"

			if [ "$KUBERNETES_REPLICAS" != "" ]; then
				sed -i "s/replicas:.*$/replicas: $KUBERNETES_REPLICAS/g" "$KUBE_SVC_FILE"
			fi

			if [ "$KUBERNETES_CRED" != "" ]; then
				printf "      imagePullSecrets:\n        - name: $KUBERNETES_CRED" >> "$KUBE_SVC_FILE"
			fi

			# yamllint "$KUBE_SVC_FILE"

			KUBE_SERVICE_CFG="$KUBE_SVC_FILE"
		fi

		# Set image name to new prepared image
		sed -i "s/image:.*$/image: $DOCKER_IMAGE_SED/g" "$KUBE_SERVICE_CFG"
		ds_debug_cat "$KUBE_SERVICE_CFG"

		kubectl create -f "$KUBE_SERVICE_CFG" --namespace=$KUBERNETES_NAMESPACE
	else
		infof "Kubernetes service $KUBE_SERVICE exists. Applying new image $DOCKER_IMAGE ... "
		kubectl set image deployment $KUBE_SERVICE "$KUBE_SERVICE=$DOCKER_IMAGE" --namespace=$KUBERNETES_NAMESPACE
		success "done"
	fi

	if [ "$KUBERNETES_NGINX_SERVICE_HOST" = "" ]; then
		KUBERNETES_NGINX_SERVICE_HOST="$SERVICE_NAME"
	fi


	if [ "$KUBERNETES_INGRESS" != "" ]; then
		if [ "$KUBERNETES_NGINX_SERVICE_PORT" = "" ]; then
			KUBERNETES_NGINX_SERVICE_PORT="80"
		fi
		ds_kube_ingress_nginx "$KUBERNETES_NGINX_SERVICE_HOST" "$KUBE_SERVICE" "$KUBERNETES_NGINX_SERVICE_PORT" "$KUBERNETES_NAMESPACE"
	fi
}
