# EKS gyakorló projekt: NLB + Traefik Ingress controller

Két Flask alkalmazás (`service-a`, `service-b`) egy EKS clusteren, előttük egy L4-es AWS Network Load
Balancer és egy clusteren belüli L7-es Ingress controller (Traefik). Az útválasztást szabványos
Kubernetes `Ingress` objektumok írják le. Az infrastruktúra Terraformmal (saját modulokkal), a
manifestek Kustomize-zal készülnek.

A részletes, lépésről lépésre útmutató (miért, hol, mit, hogyan ellenőrizd) a
[docs/notes.md](docs/notes.md)-ben van.

## Architektúra

```
kliens ──HTTP :80──▶ NLB (<cluster>-nlb, internet-facing, target type: ip)
                      │  TCP :8000 a pod IP-re, kliens IP megőrizve; health check: HTTP :8080/ping
                      ▼
                     Traefik Ingress controller (2 pod, namespace: traefik)
                      │  Ingress szabályok (IngressClass: traefik)
          /api/sa ────┴──── /api/sb
             ▼                 ▼
       Service service-a   Service service-b   (ClusterIP :80)
             ▼                 ▼
         podok :8080       podok :8080          (namespace: demo)
```

| Elem | Ki hozza létre |
|---|---|
| VPC, subnetek (`kubernetes.io/role/elb` / `internal-elb` tagekkel), NAT | Terraform, `modules/vpc` |
| EKS cluster, node group, OIDC (IRSA), security groupok (az NLB-é is) | Terraform, `modules/eks` |
| ECR repók | Terraform, `modules/ecr` |
| AWS Load Balancer Controller (Helm, IRSA szereppel) | Terraform, `modules/lb-controller` |
| Traefik (Helm): Deployment, LoadBalancer Service az NLB annotációkkal, IngressClass | Terraform, `modules/traefik` |
| Az NLB maga | az AWS Load Balancer Controller, a Traefik Service-éből |
| Appok és az Ingress | `kubectl apply -k` (`k8s/base` + a `render.sh` által generált overlay) |

## Előfeltételek

- AWS fiók és egy IAM user jogosultságokkal (VPC, EKS, IAM, ECR, ELB), beállított AWS CLI (`aws sts get-caller-identity` működik)
- Terraform >= 1.6
- kubectl
- Docker buildx-szel (az image-ek `linux/amd64`-re készülnek)
- curl
- A Helm CLI nem kötelező (a Terraform Helm providere telepít), de a hibakereséshez hasznos.

## Indítás

1. **Változók.** Másold le a mintát, és írd át: a `cluster_name`-ben a saját neved (az IAM nevek accountszinten
   egyediek), a `nlb_ingress_cidrs`-ben pedig azt, honnan legyen elérhető az NLB (`["0.0.0.0/0"]` vagy a saját IP-d `/32`-vel).

   ```bash
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   ```

2. **Init és apply.** Az első apply kb. 15–20 perc (az EKS cluster és a node group a leghosszabb). Nulláról a plan
   **57 erőforrást** hoz létre.

   ```bash
   cd terraform
   terraform init
   terraform plan -out tfplan
   terraform apply tfplan
   ```

3. **kubeconfig.**

   ```bash
   $(terraform output -raw kubeconfig_command)
   cd ..
   kubectl get nodes          # 3 Ready node
   ```

4. **Image-ek build és push az ECR-be.**

   ```bash
   ./scripts/build-push.sh 1.0.0
   ```

5. **Overlay generálása** (az image címek cseréje az ECR címre és a tagre).

   ```bash
   ./scripts/render.sh 1.0.0
   kubectl kustomize k8s/overlays/local     # ellenőrzés: az image-ek az ECR-re mutatnak
   ```

6. **Appok és Ingress telepítése.**

   ```bash
   kubectl apply -k k8s/overlays/local
   ```

## Teszt a kész rendszeren

```bash
kubectl -n traefik get pods,svc            # 2 Running Traefik pod, a Service-en az NLB DNS neve
kubectl -n demo get ingress                # CLASS: traefik, ADDRESS: az NLB DNS neve
kubectl -n demo get pods,svc               # 2-2 Running app pod, két ClusterIP Service

# Az NLB címe (a DNS feloldás és a targetek egészségessé válása 2–3 percig tarthat)
NLB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "$NLB"

curl -i "http://$NLB/api/sa"               # 200  Hello from Service A!
curl -i "http://$NLB/api/sb"               # 200  Hello from Service B!
curl -i "http://$NLB/nincs-ilyen"          # 404  404 page not found (a Traefik válaszol)

# A Traefik logjai: az access log első mezője a kliens IP (a saját publikus IP-d)
kubectl -n traefik logs deploy/traefik --tail=20
# Az LB Controller logjai (ha az NLB nem jön létre)
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50
```

## Lebontás

```bash
./scripts/teardown.sh
```

A script a helyes sorrendben bont:

1. törli az appokat és az Ingresst;
2. törli a Traefik release-t (`terraform destroy -target=module.traefik`), így az LB Controller törli az NLB-t;
3. megvárja, amíg az NLB (`<cluster>-nlb`) eltűnik;
4. lefuttatja a teljes `terraform destroy`-t.

A két destroy megerősítést kér. A végén költségellenőrzést futtat. Ennek a kimenetében ne legyen a te
clusteredhez tartozó load balancer, NAT gateway vagy EKS cluster. A megosztott accountban más projektek
erőforrásai is megjelenhetnek, a sajátjaidat a névről ismered fel:

```
- Load balancerek:
- Futó NAT gatewayek:
- EKS clusterek:
```

Ha valami mégis megmaradt, nézd meg az EC2 konzolban (Load Balancers, Target Groups, NAT Gateways) és az
EKS konzolban, mert ezek óradíjasak.
