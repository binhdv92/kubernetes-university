kubectl --context k3s-mes-lab apply -f sample-apps/nginx-hello/k8s.yaml 
kubectl --context k3s-mes-lab apply -f sample-apps/nginx-hello/ingress.yaml 
kubectl --context k3s-mes-lab apply -f sample-apps/fastapi-hostname/k8s.yaml   
kubectl --context k3s-mes-lab apply -f sample-apps/fastapi-hostname/k8s-registry.yaml
kubectl --context k3s-mes-lab apply -f sample-apps/fastapi-hostname/ingress.yaml  

# kubectl --context k3s-mes-lab apply -f sample-apps/registry/ingress.yaml
# kubectl --context k3s-mes-lab delete -f sample-apps/registry/k8s.yaml