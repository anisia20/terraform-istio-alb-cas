# EKS infrastructure by Terraform
```sh
terraform init
terraform plan
terraform apply
```

## Argocd
### 패스워드 확인
```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

```yaml
...
    alb.ingress.kubernetes.io/actions.ssl-redirect: '{"Type": "redirect", "RedirectConfig":
      { "Protocol": "HTTPS", "Port": "443", "StatusCode": "HTTP_301"}}'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-northeast-2:123:certificate/123123
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS": 443}, {"HTTP": 80}]'
...
```

## istio
```sh
kubectl get pods -n istio-system
```

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
  name: istiocontrolplane
spec:
  profile: default
  components:
    egressGateways:
    - name: istio-egressgateway
      enabled: true
      k8s:
        hpaSpec:
          minReplicas: 2
    ingressGateways:
    - name: istio-ingressgateway
      enabled: true
      k8s:
        hpaSpec:
          minReplicas: 2
    pilot:
      enabled: true
      k8s:
        hpaSpec:
          minReplicas: 2
  meshConfig:
    enableTracing: true
    defaultConfig:
      holdApplicationUntilProxyStarts: true
    accessLogFile: /dev/stdout
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
```

```sh
istioctl install -f istio-operator.yaml
kubectl get pods -n istio-system
kubectl label namespace default istio-injection=enabled
kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="status-port")].nodePort}'
## 포트 확인 30566 yaml 변경
```

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
  name: istiocontrolplane
spec:
  profile: default
  values:
    global:
      proxy:
        resources:
          requests:
            cpu: 200m
            memory: 128Mi
            ephemeral-storage: "1Gi"
          limits:
            cpu: 2000m
            memory: 1024Mi
            ephemeral-storage: "1Gi"
  meshConfig:
    enableTracing: true
    defaultConfig: 
      holdApplicationUntilProxyStarts: true
    accessLogFile: /dev/stdout 
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
  components:
    pilot:
      enabled: true
    egressGateways:
      - name: istio-egressgateway
        enabled: true
    ingressGateways:
      # ALB
      - name: istio-ingressgateway
        enabled: true
        label:
          istio: ingressgateway
        k8s:
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
              ephemeral-storage: "1Gi"
            limits:
              cpu: 2000m
              memory: 1024Mi
              ephemeral-storage: "2Gi"
          hpaSpec:
            minReplicas: 2
            maxReplicas: 4
          serviceAnnotations:  # Health check 관련 정보
            alb.ingress.kubernetes.io/healthcheck-path: /healthz/ready
            alb.ingress.kubernetes.io/healthcheck-port: "30782" # Status Port에서 지정한 nodePort 지정
          service:
            type: NodePort # ingress gateway 의 NodePort 사용
            ports:
              - name: status-port
                protocol: TCP
                port: 15021
                targetPort: 15021
                nodePort: 30782 # 요기!
              - name: http2
                protocol: TCP
                port: 80
                targetPort: 8080
              - name: https
                protocol: TCP
                port: 443
                targetPort: 8443
```

```sh
istioctl install -f istio-operator.yaml
## kubectl delete mutatingwebhookconfigurations istio-revision-tag-default 삭제시 웹 훅 삭제 필요
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-alb
  namespace: istio-system
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:ap-northeast-2:123:certificate/123123"
    alb.ingress.kubernetes.io/actions.ssl-redirect: '{"Type": "redirect", "RedirectConfig": { "Protocol": "HTTPS", "Port": "443", "StatusCode": "HTTP_301"}}'
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /*
            pathType: ImplementationSpecific
            backend:
              service:
                name: ssl-redirect
                port:
                  name: use-annotation
          - path: /*
            pathType: ImplementationSpecific
            backend:
              service:
                name: istio-ingressgateway
                port:
                  number: 80
```
