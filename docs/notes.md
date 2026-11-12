# EKS forgalmi bejárat: NLB + Traefik Ingress controller, lépésről lépésre

Ez a jegyzet egy teljes, újra végigjárható útmutató. Aki a `SziNo/eks-alb-ingress-practice` repó
`e1ecae3` commitjából indul, és sorban végigmegy a lépéseken, ugyanide jut: a régi, kézzel írt nginx
reverse proxy (DaemonSet + ConfigMap) helyett egy szabványos Ingress controller (Traefik) fut egy L4-es
NLB mögött, és az útválasztást Ingress objektumok írják le.

Minden lépésnél leírom, **mit** és **miért** csinálunk, **hol** (fájl és a fájlon belüli hely), a
**kódot**, és egy **ellenőrzést** a várt kimenettel. A parancsok a repó gyökeréből futnak, ha nincs
másképp jelölve.

## Tartalom

- [A cél egy ábrán](#a-cél-egy-ábrán)
- [0. lépés: honnan indultunk](#0-lépés-honnan-indultunk)
- [Döntések a felépítés előtt](#döntések-a-felépítés-előtt)
- [1. Terraform](#1-terraform)
- [2. Kubernetes](#2-kubernetes)
- [3. Scriptek](#3-scriptek)
- [4. Ellenőrzés és teszt](#4-ellenőrzés-és-teszt)
- [5. A régi és az új megoldás összevetése](#5-a-régi-és-az-új-megoldás-összevetése)
- [6. Gyakorló feladat: service-c](#6-gyakorló-feladat-service-c)
- [7. Buktatók és tanulságok](#7-buktatók-és-tanulságok)

## A cél egy ábrán

```
                    internet
                       │  TCP 80 (forrás: nlb_ingress_cidrs)
                       ▼
        ┌──────────────────────────────┐   NLB SG: be 80, ki 8000/8080 a node SG felé
        │ NLB  <cluster>-nlb (L4)      │   publikus subnetek (kubernetes.io/role/elb)
        │ target type: ip              │   létrehozza: AWS Load Balancer Controller
        └──────────────┬───────────────┘
                       │  TCP 8000 a pod IP-re (kliens IP megőrizve)
                       │  HTTP GET :8080/ping (health check)
                       ▼
        ┌──────────────────────────────┐   node SG: be 8000/8080 az NLB SG felől
        │ Traefik podok (2 replika)    │   namespace: traefik, Helm release a Terraformból
        │ L7: Ingress szabályok        │   IngressClass: traefik
        └───────┬──────────────┬───────┘
     /api/sa    │              │   /api/sb        (Ingress demo/demo, pathType: Prefix)
                ▼              ▼
          service-a:80     service-b:80           (ClusterIP Service → EndpointSlice)
                │              │
                ▼              ▼
          pod :8080        pod :8080              (Flask + gunicorn, namespace: demo)
```

A régi megoldásban az NLB (instance target type) a node-ok NodePortjára küldött, ott a DaemonSetként
futó nginx fogadta, és egy ConfigMapből betöltött `default.conf` `location` blokkjai döntöttek. Most az
NLB közvetlenül a Traefik podokra küld, a Traefik pedig a Kubernetes API-ból olvassa az Ingress
objektumokat, és azokból építi fel az útválasztást.

---

## 0. lépés: honnan indultunk

### 0.1 A template és az eredeti architektúra

A kiindulás a `SziNo/EKS-nginx-proxy` repó, egy kész, működő bootcamp feladat. A GitHubon a
„Use this template” gombbal ebből új repó készült: `SziNo/eks-alb-ingress-practice`. A template-ből
készült repó egyetlen „Initial commit”-tal indul (`fcd3e6c`), az előzmény nem jön át.

Az eredeti architektúra:

| Réteg | Elem | Fájl(ok) |
|---|---|---|
| Alkalmazás | Két Flask app (`service-a`, `service-b`), útvonalak: `/api/sa`, `/api/sb`, `/healthz`; gunicorn a 8080-on, nem root (UID 10001) | `apps/service-a/`, `apps/service-b/` (nem `src/`) |
| Kubernetes | `demo` namespace, a két app Deploymentje (2-2 replika) és ClusterIP Service-e (80 → 8080) | `k8s/base/namespace.yaml`, `service-a.yaml`, `service-b.yaml` |
| Bejárat (L7) | nginx reverse proxy **DaemonSet** (`nginxinc/nginx-unprivileged`, 8080), a konfiguráció egy **ConfigMap** `default.conf` kulcsából (`/healthz`, `/api/sa`, `/api/sb`, minden más 404) | `k8s/base/nginx-daemonset.yaml`, `nginx-configmap.yaml` |
| Bejárat (L4) | internet-facing **NLB** egy LoadBalancer Service-ből: `aws-load-balancer-type: external`, `nlb-target-type: instance`, `externalTrafficPolicy: Local`, saját NLB security group (a render.sh patch-eli be az annotációba) | `k8s/base/nginx-service.yaml`, `scripts/render.sh` |
| Terraform | saját modulok: `vpc`, `eks`, `ecr`, `lb-controller` (AWS Load Balancer Controller Helm release + IRSA) | `terraform/` |
| Scriptek | `build-push.sh` (image build + ECR push), `render.sh` (Kustomize overlay generálás), `teardown.sh` (lebontás + költségellenőrzés) | `scripts/` |

### 0.2 A forgalom bejáratának kivétele (commit `379a0bd`)

Gyakorlásként a forgalom teljes bejáratát kivettük, hogy újra fel lehessen építeni: az nginxet, az NLB-t
és az AWS Load Balancer Controllert, mindent, ami ezekhez kellett. Az EKS OIDC provider és a `tls`
provider **maradt**, mert az IRSA-hoz (és így a később visszakerülő LB Controllerhez) kell.

A változás teljes egészében megnézhető:

```bash
git show --stat 379a0bd     # 26 fájl, 26 beszúrás, 756 törlés
git show 379a0bd -- terraform/modules/eks/security-groups.tf   # egy fájl diffje
```

Az alábbi parancsok a commit diffjéből vannak összeállítva: ezekkel a kivétel megismételhető.
A törlések parancssorból mennek, a fájlon belüli módosítások szerkesztővel (a régi és az új tartalom
a `git show` kimenetében pontosan látszik).

**Kubernetes (`k8s/base/`)**

```bash
git rm k8s/base/nginx-configmap.yaml k8s/base/nginx-daemonset.yaml k8s/base/nginx-service.yaml
# a kustomization.yaml resources listájából a három hivatkozás törlése:
sed -i '/nginx-configmap.yaml/d; /nginx-daemonset.yaml/d; /nginx-service.yaml/d' k8s/base/kustomization.yaml
```

**Terraform**

```bash
git rm -r terraform/modules/lb-controller     # main.tf, variables.tf, outputs.tf, versions.tf, iam_policy.json
```

Fájlonként, szerkesztővel:

| Fájl | Mi került ki |
|---|---|
| `terraform/main.tf` | a `module "lb_controller"` blokk; az eks modulhívásból a `nlb_ingress_cidrs = var.nlb_ingress_cidrs` sor; a komment „(az NLB-é is)” része |
| `terraform/providers.tf` | a teljes `provider "helm"` blokk (exec alapú token) |
| `terraform/versions.tf` | a `helm` provider a `required_providers`-ből; a `required_version` kommentjéből a `precondition` szó (már nem volt precondition a kódban) |
| `terraform/.terraform.lock.hcl` | a `hashicorp/helm` 3.3.0 bejegyzés: ezt nem kézzel, hanem a `terraform init -backend=false` vette ki, mert már egyik modul sem kérte a helm providert |
| `terraform/variables.tf` | `lb_controller_chart_version` (alapérték `"3.6.2"`), `nlb_ingress_cidrs` |
| `terraform/outputs.tf` | `nlb_security_group_id` |
| `terraform/terraform.tfvars.example` | `nlb_ingress_cidrs = ["0.0.0.0/0"]` és a kommentje; a subnet kommentből az „NLB” |
| `terraform/modules/vpc/main.tf` | a publikus subnetek `kubernetes.io/role/elb = "1"` és a privátok `kubernetes.io/role/internal-elb = "1"` tagje, és az ezekre utaló kommentek (internet gateway, publikus subnet) |
| `terraform/modules/eks/security-groups.tf` | az `aws_security_group.nlb`; az `nlb_http` (ingress, for_each a CIDR-eken) és `nlb_to_nodes` (egress) szabály; a `node_from_nlb` szabály (NodePort tartomány az NLB SG felől); a `cluster_to_node_ports` térképből a `lbc_webhook = 9443`; a node SG `kubernetes.io/cluster/<név> = owned` tagje; a holt `node_port_from` / `node_port_to` locals (már semmi nem használta) |
| `terraform/modules/eks/variables.tf` | `nlb_ingress_cidrs` |
| `terraform/modules/eks/outputs.tf` | `nlb_security_group_id`; a `cluster_endpoint` és a `cluster_certificate_authority_data` description-jéből a „(a Helm provider használja)” |
| `terraform/modules/eks/access.tf`, `addons.tf`, `node-group.tf`, `oidc.tf` | csak kommentek: a Helm providerre, az nginxre, az LB Controllerre és a DaemonSetre utaló részek (pl. a `node-group.tf`-ből „Az LB Controllernek nem kell IMDS…” sor) |

**Scriptek**

| Fájl | Mi került ki |
|---|---|
| `scripts/render.sh` | az `SG_ID=$(terraform … output -raw nlb_security_group_id)` sor, és a generált overlay `patches:` része, amely az NLB SG ID-ját a `nginx-proxy` Service `aws-load-balancer-security-groups` annotációjába írta; a záró `echo`-ból az SG |
| `scripts/teardown.sh` | a `NAMESPACE="demo"` változó, az NLB-re utaló kommentek, és a várakozó ciklus, amely `k8s-demo-` névelőtagú load balancereket keresett, amíg el nem tűntek |

### 0.3 Hogyan ellenőriztük a kivételt

```bash
cd terraform
terraform init -backend=false   # a helm kikerül a .terraform.lock.hcl-ből
terraform fmt -check -recursive # üres kimenet, exit 0
terraform validate              # Success! The configuration is valid.
cd ..
kubectl kustomize k8s/base      # csak namespace, 2 Deployment, 2 Service
for f in scripts/*.sh; do bash -n "$f"; done   # üres kimenet
# Záró keresés: maradt-e valahol utalás a kivett elemekre?
grep -rniE "lb.controller|load.?balancer|nlb|nginx|helm|role/elb" \
  --exclude-dir=.git --exclude-dir=.terraform --exclude=README.md --exclude=notes.md .
```

A záró grep-nél a dokumentáció (README, notes) találatai várhatók voltak, mert azok akkor még a régi
architektúrát írták le; a fenti `--exclude` ezeket szűri.
A `teardown.sh` költségellenőrzése (`aws elbv2 describe-load-balancers`) szándékosan maradt: az a lebontás
utáni ellenőrzés része, nem a bejáraté.

### 0.4 A cluster átnevezése (commit `e1ecae3`)

Ugyanabban a megosztott AWS accountban fut egy másik projekt is, a régi `szino-nginx-proxy-demo`
névvel. Az IAM szerep nevek accountszinten egyediek, és sok más név (security groupok, ECR repók,
a state bucket) is a cluster nevéből képződik, ezért a gyakorló projekt saját nevet kapott:
`szino-nginx-proxy-demo` → `szino-alb-practice`.

```bash
grep -rn "szino-nginx-proxy-demo\|nginx-proxy-demo-tfstate\|eks-nginx-proxy/" --exclude-dir=.git .
sed -i 's/szino-nginx-proxy-demo/szino-alb-practice/g' \
  terraform/terraform.tfvars.example terraform/main.tf terraform/modules/ecr/main.tf scripts/build-push.sh
# A backend komment: a bucket név és a state key
sed -i 's/nginx-proxy-demo-tfstate/alb-practice-tfstate/g; s#eks-nginx-proxy/terraform.tfstate#eks-alb-ingress-practice/terraform.tfstate#' \
  terraform/versions.tf
grep -rn "nginx-proxy-demo\|eks-nginx-proxy/" --exclude-dir=.git --exclude=README.md --exclude=notes.md .   # üres
```

A `tfvars.example`-ben ez a tényleges érték, a többi helyen komment (példa repónév, a backend blokk).

---

## Döntések a felépítés előtt

### Melyik Ingress controller?

A vizsgálat 2026-11-12-én készült, a források a parancsok, így bármikor megismételhető:

```bash
# Chart verziók
helm repo add ingress-nginx   https://kubernetes.github.io/ingress-nginx
helm repo add traefik         https://traefik.github.io/charts
helm repo add haproxy-ingress https://haproxy-ingress.github.io/charts
helm repo add haproxytech     https://haproxytech.github.io/helm-charts
helm repo add nginx-stable    https://helm.nginx.com/stable
helm repo update
helm search repo ingress-nginx/ingress-nginx --versions | head -3
helm search repo traefik/traefik --versions | head -3
# A projekt állapota (archivált-e, utolsó push, csillagok) és az utolsó kiadások
gh api repos/kubernetes/ingress-nginx --jq '{archived, pushed_at, stars: .stargazers_count}'
gh api repos/kubernetes/ingress-nginx/releases?per_page=3 --jq '.[] | "\(.tag_name) \(.published_at)"'
# ugyanez: traefik/traefik, jcmoraisjr/haproxy-ingress, haproxytech/kubernetes-ingress, nginx/kubernetes-ingress
```

| Controller | Forrás | Eredmény (2026-11-12) |
|---|---|---|
| **ingress-nginx** (kubernetes/ingress-nginx) | `gh api repos/kubernetes/ingress-nginx` | **`archived: true`**, utolsó push 2026-03-23 |
| | `gh api …/releases` | utolsó kiadás: `helm-chart-4.15.1` 2026-03-19 (és ugyanaznap a 4.14.5, 4.13.9) |
| | `helm search repo ingress-nginx/ingress-nginx` | chart 4.15.1, controller 1.15.1, azóta semmi |
| **Traefik** (traefik/traefik) | `gh api repos/traefik/traefik` | nem archivált, utolsó push 2026-11-11, ~65 500 csillag |
| | `gh api …/releases` | v3.7.18 (2026-11-10), v3.8.0-rc.2 (2026-11-10), v2.11.62 (2026-11-10) |
| | `helm search repo traefik/traefik --versions` | legújabb chart **42.3.2** (app v3.7.17, a chart repó indexében 2026-11-10-i); előtte **42.3.1** (ugyanaz a v3.7.17, 2026-11-06) |
| HAProxy Ingress (jcmoraisjr/haproxy-ingress) | `gh api …` | aktív: v0.16.3 (2026-10-26), v0.17.0-beta.2; ~1 200 csillag; a repó leírása már „N42 Gateway” |
| HAProxy Tech (haproxytech/kubernetes-ingress) | `gh api …` | aktív: v3.2.19 (2026-10-30), chart 1.54.4; ~870 csillag |
| F5 NGINX Ingress (nginx/kubernetes-ingress) | `gh api …` | aktív: v5.7.1 (2026-11-05), chart 2.8.1; ~5 100 csillag |

**Döntés: Traefik, chart `42.3.1` rögzítve.**

Miért nem a legújabb 42.3.2? Mindkettő ugyanazt a Traefik v3.7.17-et telepíti, és a chart értékei
(`helm show values`) is azonosak, de a 42.3.2 a döntéskor csak két napos volt. Egy friss kiadásnak érdemes
egy-két hetet hagyni: ha hibás, addig általában kiderül, és jön egy javító kiadás. Ellenőrzés:

```bash
diff <(helm show values traefik/traefik --version 42.3.1) <(helm show values traefik/traefik --version 42.3.2) && echo IDENTICAL
python3 -c "import yaml,os; [print(e['version'], e['appVersion'], e['created']) for e in yaml.safe_load(open(os.path.expanduser('~/.cache/helm/repository/traefik-index.yaml')))['entries']['traefik'][:3]]"
```

- Az **ingress-nginx** archivált: a Kubernetes SIG Network 2025 novemberében jelentette be a visszavonulását
  (2026 márciusáig volt „best effort” karbantartás). Archivált repó = nincs több kiadás, nincs biztonsági
  javítás. Új projektbe nem való, akármilyen elterjedt volt.
- A **Traefik** aktív (heti kiadások), nagyon elterjedt, a szabványos `Ingress` erőforrást natívan kezeli,
  a Helm chartja karbantartott. Van saját CRD-je (`Middleware`), amellyel útvonal átírás, fejléc
  módosítás stb. megoldható (a 6. fejezet feladata ezt használja). Van egy `kubernetesIngressNGINX`
  providere is, amely az ingress-nginx annotációit érti, ezért az ingress-nginx-ről való átállásnál az
  egyik ajánlott út.
- Az **F5 NGINX Ingress** más termék, mint az ingress-nginx (más annotációk, más konfiguráció); a név miatt
  könnyű összekeverni őket. A két HAProxy controller kisebb közösségű.

### Target type és externalTrafficPolicy

| | `instance` (régi) | `ip` (új) |
|---|---|---|
| Hová küld az NLB | a node-ok **NodePortjára** | közvetlenül a **pod IP-re** (a VPC CNI miatt a pod IP egy valódi VPC cím a node ENI-jén) |
| Útvonal a node-on | NodePort → kube-proxy (iptables) → pod, akár másik node-on | nincs NodePort, nincs kube-proxy ugrás |
| Kliens IP | `Cluster` policynál elveszik (SNAT a node-on), ezért kellett a `Local` és a DaemonSet (minden node-on legyen helyi pod) | target group attribútummal (`preserve_client_ip.enabled=true`) megmarad |
| Node SG szabály | NodePort tartomány (30000–32767) | a pod portja (itt 8000 és 8080) |
| `externalTrafficPolicy` | lényeges | **nincs hatása az adatútra**, mert az NLB nem a NodePortot használja |

**Döntés: `ip` target type, kliens IP megőrzéssel; az `externalTrafficPolicy` marad az alapértelmezett
`Cluster`, és a Service `allocateLoadBalancerNodePorts: false`, vagyis NodePort sem jön létre.**

- `ip` targetnél a kliens IP megőrzése (TCP) **alapból ki van kapcsolva**: ilyenkor az NLB saját privát
  IP-je lenne a forrás. Ezért kell a `service.beta.kubernetes.io/aws-load-balancer-target-group-attributes:
  preserve_client_ip.enabled=true` annotáció.
- Mivel az NLB-nek saját security groupja van, a node SG szabálya az **NLB SG-re hivatkozik**. Így megőrzött
  kliens IP mellett sem kell a kliensek CIDR-jeit a node SG-be felvenni.
- **X-Forwarded-For:** a Traefik a `web` entrypointon a `forwardedHeaders.trustedIPs` beállítás alapján dönt.
  Ez üres (alapérték), ezért a klienstől érkező `X-Forwarded-*` fejléceket nem fogadja el (egy kliens nem
  tudja meghamisítani a saját IP-jét), és a valódi forrás IP-t (a megőrzött kliens IP-t) írja az
  `X-Forwarded-For` és az `X-Real-Ip` fejlécbe. A backend így megkapja a kliens IP-t.
- **Health check:** HTTP `GET /ping` a Traefik `traefik` entrypointján (8080). Egy TCP check akkor is zöld
  lenne, ha a port már nyitva van, de a Traefik még nem kész (pl. még nem olvasta be a szabályokat).

### Egyéb döntések

- **Fix NLB név** (`<cluster>-nlb`, `aws-load-balancer-name` annotáció): a teardown név szerint, egyértelműen
  tudja megvárni a törlését a megosztott accountban is. Ára: lásd a [7. fejezetet](#7-buktatók-és-tanulságok).
- **A node SG szabályait a Terraform kezeli**, a controller backend szabálykezelése ki van kapcsolva
  (`manage-backend-security-group-rules: "false"`). Ha mindkettő felvenné ugyanazt a szabályt
  (forrás: NLB SG, port: 8000), az AWS a második létrehozását duplikátumként elutasítaná.
- **A portok egy helyen**: a root `locals.tf`-ben (`ingress_controller_ports`), ebből kapja az értékeket a
  Traefik modul (Helm) és az eks modul (SG szabályok) is.

---

## 1. Terraform

### 1.1 Subnet tagek

**Mit és miért.** Az AWS Load Balancer Controller a subneteket tagek alapján választja ki (subnet
auto-discovery): internet-facing load balancerhez a `kubernetes.io/role/elb = 1`, belsőhöz
(`scheme: internal`) a `kubernetes.io/role/internal-elb = 1` tagű subneteket keresi, AZ-nként egyet.
Az internet-facing NLB-nek a **publikus** subnetekben a helye (itt van route az internet gatewayre), a
belsőnek a **privátokban**. Tag nélkül a Service eseményei között
`Failed build model due to unable to resolve at least one subnet` hiba jelenik meg, és nem jön létre NLB.
A privát tag most nem kell (nincs belső LB), de így egy későbbi belső NLB is azonnal működik.

**Hol.** `terraform/modules/vpc/main.tf`, az `aws_subnet.public` és az `aws_subnet.private` erőforrás
`tags` blokkja (és a kommentek fölöttük; az internet gateway kommentje is).

Régi:

```hcl
# Publikus subnetek AZ-nként: ide kerül a NAT gateway.
resource "aws_subnet" "public" {
  # ...
  tags = {
    Name = "${var.name}-public-${each.key}"
  }
}

# Privát subnetek AZ-nként: itt futnak a node-ok és a podok, kívülről közvetlenül nem érhetők el.
resource "aws_subnet" "private" {
  # ...
  tags = {
    Name = "${var.name}-private-${each.key}"
  }
}
```

Új:

```hcl
# Internet gateway: ezen keresztül éri el a publikus subnet az internetet (és az internet az NLB-t).
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-igw"
  }
}

# Publikus subnetek AZ-nként: ide kerül a NAT gateway és az internet felé néző NLB.
# A kubernetes.io/role/elb tag alapján választja ezeket az AWS Load Balancer Controller
# internet-facing load balancerhez (AZ-nként egy taggelt subnetet keres; tag nélkül
# "unable to resolve at least one subnet" hibával nem jön létre az NLB).
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value
  # Nincs itt olyan gép, aminek automatikusan publikus IP kellene: a node-ok a privát
  # subnetekben vannak, a NAT gateway saját EIP-t kap, az NLB a saját címeit kezeli.
  # A true csak felesleges kockázat lenne: egy ide indított EC2 azonnal elérhető lenne az internetről.
  map_public_ip_on_launch = false

  tags = {
    Name                     = "${var.name}-public-${each.key}"
    "kubernetes.io/role/elb" = "1"
  }
}

# Privát subnetek AZ-nként: itt futnak a node-ok és a podok, kívülről közvetlenül nem érhetők el.
# A kubernetes.io/role/internal-elb tag a belső (scheme: internal) load balancerekhez jelöli ki
# őket. Most nincs belső LB, de a tag nélkül egy későbbi belső NLB nem találna subnetet.
resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = {
    Name                              = "${var.name}-private-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}
```

**Ellenőrzés.**

```bash
grep -n 'kubernetes.io/role' terraform/modules/vpc/main.tf
```

```
34:# A kubernetes.io/role/elb tag alapján választja ezeket az AWS Load Balancer Controller
50:    "kubernetes.io/role/elb" = "1"
55:# A kubernetes.io/role/internal-elb tag a belső (scheme: internal) load balancerekhez jelöli ki
66:    "kubernetes.io/role/internal-elb" = "1"
```

Apply után: `aws ec2 describe-subnets --filters Name=tag:kubernetes.io/role/elb,Values=1 --query 'Subnets[].SubnetId'`
három subnetet ad (a publikusakat).

### 1.2 A node SG `kubernetes.io/cluster/<név>` tagje

**Mit és miért.** Az LB Controller így ismeri fel a node-ok security groupjai közül a cluster SG-jét, ha a
backend szabályokat neki kell felvennie (`manage-backend-security-group-rules: "true"`), vagy ha egy
node/pod ENI-n több SG is van. Ilyenkor a tagelt SG-be teszi a szabályt; ha nem talál pontosan egyet,
hibával áll meg (a hibaüzenet lényege: `expected exactly one securityGroup tagged with kubernetes.io/cluster/<név>`).

Őszintén: a mostani beállításban (egy SG a node ENI-n, és a backend szabályokat a Terraform kezeli) a
controller nem használja ezt a taget. Azért kerül fel mégis, mert a controller dokumentációja előírja, és
egy későbbi LoadBalancer Service (saját SG annotáció nélkül, ahol a controller kezeli a backend
szabályokat), vagy egy második SG a node-on azonnal elakadna nélküle. Az `owned` érték azt jelzi, hogy ez
a SG ehhez a clusterhez tartozik.

**Hol.** `terraform/modules/eks/security-groups.tf`, `aws_security_group.node`.

Régi:

```hcl
# Security group a node-oknak (a launch template rakja rájuk).
resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node"
  description = "EKS managed node group"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.cluster_name}-node"
  }
}
```

Új:

```hcl
# Security group a node-oknak (a launch template rakja rájuk). A kubernetes.io/cluster tag
# alapján találja meg az AWS Load Balancer Controller azt a SG-t, amelybe a backend szabályait
# felvenné, ha egy node ENI-n több SG is van (vagy ha egy Service-nél ő kezeli a backend szabályokat).
resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node"
  description = "EKS managed node group"
  vpc_id      = var.vpc_id

  tags = {
    Name                                        = "${var.cluster_name}-node"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}
```

**Ellenőrzés.** `grep -n 'kubernetes.io/cluster' terraform/modules/eks/security-groups.tf` → a 37. sorban
ott a tag. Apply után:
`aws ec2 describe-security-groups --filters Name=tag-key,Values=kubernetes.io/cluster/szino-alb-practice --query 'SecurityGroups[].GroupName'`
→ `["szino-alb-practice-node"]`.

### 1.3 A 9443-as webhook szabály (cluster SG → node SG)

**Mit és miért.** Az LB Controller admission webhookokat regisztrál (pl. egy mutating webhookot a Service-ekre,
ami a LoadBalancer Service-ekre beállítja a `loadBalancerClass`-t, és TargetGroupBinding
validálást). Egy webhook hívásakor a **control plane** (az AWS által üzemeltetett API szerver, a mi VPC-nkben
lévő ENI-ken keresztül) kapcsolódik a controller podjához, annak a 9443-as portjára. A pod IP a node ENI-jén
van, ezért a node SG dönt: ha a cluster SG felől nincs engedélyezve a 9443, a webhook hívás timeoutol, és a
Traefik LoadBalancer Service létrehozása hibára fut (`failed calling webhook "mservice.elbv2.k8s.aws"`).
A Helm release ilyenkor elbukik.

**Hol.** `terraform/modules/eks/security-groups.tf`, a `locals.cluster_to_node_ports` térkép. A szabályt a
meglévő `node_from_cluster` erőforrás for_each-e hozza létre (új kulccsal új szabály, a többit nem érinti).

Régi:

```hcl
  cluster_to_node_ports = {
    https   = 443   # pl. a control plane webhookjai a 443-on figyelő podok felé
    kubelet = 10250 # kubectl logs/exec, a kubelet API
  }
```

Új:

```hcl
locals {
  # A control plane által a node-okon/podokon elért portok (név => port)
  cluster_to_node_ports = {
    https       = 443   # pl. a control plane webhookjai a 443-on figyelő podok felé
    kubelet     = 10250 # kubectl logs/exec, a kubelet API
    lbc_webhook = 9443  # AWS Load Balancer Controller webhook: enélkül a LoadBalancer Service létrehozása hibára fut
  }
}
```

**Ellenőrzés.** Apply után:
`aws ec2 describe-security-group-rules --filters Name=group-id,Values=$(aws ec2 describe-security-groups --filters Name=group-name,Values=szino-alb-practice-node --query 'SecurityGroups[0].GroupId' --output text) --query "SecurityGroupRules[?FromPort==\`9443\`].Description"`
→ `["From control plane: lbc_webhook"]`.

### 1.4 Az NLB security group és a szabályai

**Mit és miért.** Az NLB-nek saját security groupja van (2023 óta az NLB is támogatja). Ez két dolgot ad:

1. Az NLB-n szűrhető, honnan jöhet forgalom (`nlb_ingress_cidrs`, tfvars-ból, alapérték nélkül: tudatos
   döntés legyen, hogy az egész internet vagy csak a saját IP-d).
2. A node SG szabálya az NLB SG-re hivatkozhat (`referenced_security_group_id`), nem kell CIDR-eket felsorolni.

Négy szabálycsoport kell, mind külön erőforrás, egymásra hivatkozva:

| Erőforrás | SG | Irány | Port | Forrás/cél |
|---|---|---|---|---|
| `nlb_http` | NLB | be | 80 | `nlb_ingress_cidrs` (for_each a CIDR-eken) |
| `nlb_to_nodes` | NLB | ki | 8000, 8080 | node SG (for_each a portokon) |
| `node_from_nlb` | node | be | 8000, 8080 | NLB SG (for_each a portokon) |

(A negyedik a 9443-as, lásd 1.3.) A 8000 a Traefik `web` entrypointja (forgalom), a 8080 a `traefik`
entrypoint (`/ping`, health check). `ip` targetnél ezek a **pod** portjai; `instance` targetnél itt a
NodePort tartomány állna.

Egy security group szabály mindkét oldalon kell: az NLB SG kimenő szabálya engedi, hogy az NLB küldjön, a
node SG bejövő szabálya, hogy a pod fogadjon. Az alapértelmezett „minden kimenő” szabályt a Terraform nem
teszi rá az általa létrehozott SG-re, ezért az NLB SG kifelé csak azt engedi, amit itt megadunk.

**Hol.** `terraform/modules/eks/security-groups.tf` (az NLB SG és a szabályok),
`terraform/modules/eks/variables.tf` (`nlb_ingress_cidrs`, `nlb_target_ports`),
`terraform/modules/eks/outputs.tf` (`nlb_security_group_id`). A portokat a root adja (1.9).

A teljes új `terraform/modules/eks/security-groups.tf` (az 1.2 és 1.3 változásai is benne vannak):

```hcl
# FONTOS: a szabályok külön erőforrások (aws_vpc_security_group_ingress_rule / egress_rule),
# nem inline ingress/egress blokkok. Inline blokkoknál a Terraform a security group ÖSSZES
# szabályát kezelné, és a következő apply törölné azokat, amelyeket más (nem a Terraform,
# pl. az AWS Load Balancer Controller) vesz fel a SG-be.

locals {
  # A control plane által a node-okon/podokon elért portok (név => port)
  cluster_to_node_ports = {
    https       = 443   # pl. a control plane webhookjai a 443-on figyelő podok felé
    kubelet     = 10250 # kubectl logs/exec, a kubelet API
    lbc_webhook = 9443  # AWS Load Balancer Controller webhook: enélkül a LoadBalancer Service létrehozása hibára fut
  }
}

# Kiegészítő security group a control plane ENI-khez (az EKS ezen felül egy saját
# "cluster security groupot" is létrehoz automatikusan).
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster"
  description = "EKS control plane (additional)"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.cluster_name}-cluster"
  }
}

# Security group a node-oknak (a launch template rakja rájuk). A kubernetes.io/cluster tag
# alapján találja meg az AWS Load Balancer Controller azt a SG-t, amelybe a backend szabályait
# felvenné, ha egy node ENI-n több SG is van (vagy ha egy Service-nél ő kezeli a backend szabályokat).
resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node"
  description = "EKS managed node group"
  vpc_id      = var.vpc_id

  tags = {
    Name                                        = "${var.cluster_name}-node"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

# Security group az NLB-nek. Az azonosítóját a Terraform közvetlenül a Traefik Service
# annotációjába írja (service.beta.kubernetes.io/aws-load-balancer-security-groups),
# így nem kell a Kubernetes manifesteket patchelni.
resource "aws_security_group" "nlb" {
  name        = "${var.cluster_name}-nlb"
  description = "Public NLB in front of the Traefik ingress controller"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.cluster_name}-nlb"
  }
}

# --- Cluster SG szabályok ---

# A node-ok elérhetik a Kubernetes API-t (443) a privát endpointon.
resource "aws_vpc_security_group_ingress_rule" "cluster_from_nodes_https" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Kubernetes API from nodes"
}

# A control plane kifelé bárhová kapcsolódhat (kubelet, webhookok a node-okon).
resource "aws_vpc_security_group_egress_rule" "cluster_all" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All outbound"
}

# --- Node SG szabályok ---

# Node-node és pod-pod forgalom: a VPC CNI miatt a podok a node ENI-jein kapnak IP-t, így ez a SG
# vonatkozik rájuk is (pl. Traefik -> service-a pod másik node-on, CoreDNS lekérdezések).
resource "aws_vpc_security_group_ingress_rule" "node_self" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
  description                  = "Node to node and pod to pod"
}

# A control plane elérheti a node-okat a szükséges portokon (lásd local.cluster_to_node_ports).
resource "aws_vpc_security_group_ingress_rule" "node_from_cluster" {
  for_each = local.cluster_to_node_ports

  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "From control plane: ${each.key}"
}

# Az NLB elérheti a Traefik podokat (target type: ip, vagyis közvetlenül a pod IP-n, ami a node
# ENI-jén van, ezért a node SG érvényes rá): a forgalmi port (web) és a health check port (ping).
# A forrás az NLB SG-je: így a kliens IP megőrzése (preserve_client_ip) mellett sem kell a
# kliensek CIDR-jeit ide felvenni. A controller backend szabálykezelése ki van kapcsolva
# (manage-backend-security-group-rules: "false"), különben ugyanezt a szabályt ő is felvenné,
# és az AWS duplikált szabályként elutasítaná.
resource "aws_vpc_security_group_ingress_rule" "node_from_nlb" {
  for_each = var.nlb_target_ports

  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.nlb.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "From NLB: ${each.key}"
}

# A node-ok kifelé bárhová kapcsolódhatnak (ECR, EKS API, S3 – a NAT gatewayen át).
resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All outbound"
}

# --- NLB SG szabályok ---

# HTTP a megadott tartományokból (tfvars: nlb_ingress_cidrs) az NLB 80-as portjára.
resource "aws_vpc_security_group_ingress_rule" "nlb_http" {
  for_each = toset(var.nlb_ingress_cidrs)

  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "HTTP from ${each.value}"
}

# Az NLB csak a node SG-be tartozó ENI-kre (a Traefik podokra) küldhet, és csak a forgalmi
# és a health check porton. Ez a node_from_nlb párja: mindkét oldalon engedélyezni kell.
resource "aws_vpc_security_group_egress_rule" "nlb_to_nodes" {
  for_each = var.nlb_target_ports

  security_group_id            = aws_security_group.nlb.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "To Traefik pods: ${each.key}"
}
```

`terraform/modules/eks/variables.tf`, a fájl végére:

```hcl
variable "nlb_ingress_cidrs" {
  description = "Honnan érhető el az NLB a 80-as porton (CIDR lista)"
  type        = list(string)
}

variable "nlb_target_ports" {
  description = "Az NLB célportjai a podokon (név => port), pl. a forgalmi és a health check port; ezekre nyit szabályt az NLB SG és a node SG között"
  type        = map(number)
}
```

`terraform/modules/eks/outputs.tf`: új output a `node_security_group_id` után, és a két description
visszakapja a „(a Helm provider használja)” részt:

```hcl
output "cluster_name" {
  description = "Az EKS cluster neve"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "A Kubernetes API címe (a Helm provider használja)"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "A cluster CA tanúsítványa base64-ben (a Helm provider használja)"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "Az IAM OIDC provider ARN-je (IRSA trust policyhoz)"
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "Az OIDC kibocsátó címe https:// nélkül (IRSA trust policy feltételeihez)"
  value       = replace(local.oidc_issuer, "https://", "")
}

output "cluster_security_group_id" {
  description = "A control plane kiegészítő security groupja"
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "A node-ok security groupja"
  value       = aws_security_group.node.id
}

output "nlb_security_group_id" {
  description = "Az NLB security groupja (a Traefik modul a Service annotációjába írja)"
  value       = aws_security_group.nlb.id
}

output "node_role_arn" {
  description = "A node IAM szerep ARN-je"
  value       = aws_iam_role.node.arn
}
```

**Ellenőrzés.** A modul önmagában nem validálható a root nélkül (a változókat a root adja); a teljes
ellenőrzés az 1.11-ben van. Apply után:

```bash
aws ec2 describe-security-group-rules --region eu-west-1 \
  --filters Name=group-id,Values=$(terraform -chdir=terraform output -raw nlb_security_group_id) \
  --query 'SecurityGroupRules[].[IsEgress,FromPort,CidrIpv4,ReferencedGroupInfo.GroupId,Description]' --output table
```

Várt: 1 bejövő (80, `0.0.0.0/0`) és 2 kimenő (8000 és 8080, a node SG ID-jával) szabály.

### 1.5 Kommentek visszaállítása az eks modulban

**Mit és miért.** A kivételkor a kommentekből kikerültek a Helm providerre és az LB Controllerre utaló
részek; ezek most újra igazak, ezért visszakerülnek. Működést nem változtat.

| Fájl | Régi | Új |
|---|---|---|
| `modules/eks/access.tf` | `Enélkül a kubectl "Unauthorized" hibát kapna.` | `Enélkül a kubectl és a Helm provider "Unauthorized" hibát kapna.` |
| `modules/eks/oidc.tf` | `így egy pod saját` | `így egy pod (pl. az LB Controller) saját` |
| `modules/eks/node-group.tf` | (nincs) | `# Az LB Controllernek nem kell IMDS: IRSA-t használ, a régiót és a vpcId-t a Helm értékekben kapja.` a `http_put_response_hop_limit` fölé |
| `modules/eks/addons.tf` | a coredns komment | kiegészítve: a Traefik nem DNS-t használ, hanem közvetlenül az EndpointSlice-okból veszi a pod IP-ket |

Az `http_put_response_hop_limit = 1` miatt a podok nem érik el az IMDS-t. Az LB Controller ezért nem tudná
onnan kiolvasni a régiót és a VPC ID-t: ezeket a Helm értékekben kapja (1.7), az AWS jogait pedig IRSA-val.

### 1.6 A Helm provider és a lock fájl

**Mit és miért.** A két Helm release (LB Controller, Traefik) a Terraform Helm providerével települ. A provider
ugyanúgy csatlakozik a clusterhez, mint a kubectl: az EKS API címe, a CA tanúsítvány és egy rövid életű token,
amit az `aws eks get-token` ad (exec). Statikus jelszó vagy kubeconfig fájl nem kell. A token annak az IAM
usernek a jogaival jár, aki a Terraformot futtatja; ő az access entry miatt cluster admin.

A root `~> 3.0`-t köt ki (a 3.x-en belül frissülhet), a modulok csak `>= 3.0`-t. A 3.x szintaxisa más, mint a
2.x-é: a `kubernetes` és az `exec` attribútum (`= { ... }`), a `set` lista.

**Hol.** `terraform/versions.tf` (`required_providers`), `terraform/providers.tf` (a fájl vége),
`terraform/.terraform.lock.hcl` (a `terraform init` írja).

`terraform/versions.tf`, a `required_providers` blokkban az `aws` és a `tls` közé, és a `required_version`
kommentje (`precondition` újra van a kódban, lásd 1.7):

```hcl
terraform {
  # 1.6: a README is ezt írja elő; az itt használt nyelvi elemek (for_each, optional, precondition) ezzel mind működnek
  required_version = ">= 1.6"
```

```hcl
    # Helm provider: az AWS Load Balancer Controller és a Traefik telepítése.
    # 3.x: ehhez kell az új szintaxis (kubernetes = { ... }, set = [ ... ]); a 2.x nem ismeri,
    # a régi blokk szintaxist pedig a 3.x nem fogadja el.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
```

`terraform/providers.tf`, a teljes új fájl:

```hcl
# Provider blokkok CSAK itt, a root modulban vannak; a saját modulok ezeket öröklik.

# AWS provider: a régiót változóból kapja. A default_tags minden AWS erőforrásra
# rákerül, így a konzolban és a számlán is látszik, mi tartozik a projekthez.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.cluster_name
      ManagedBy = "terraform"
    }
  }
}

# Helm provider (3.x szintaxis): az EKS clusterhez ugyanúgy csatlakozik, mint a kubectl.
# A kubernetes és az exec itt attribútum (= { ... }), nem blokk.
# Az exec az AWS CLI-vel kér rövid életű tokent (aws eks get-token), így nem kell
# statikus jelszót tárolni; a token az access entryben megadott admin jogot kapja.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
```

**Ellenőrzés.**

```bash
cd terraform && terraform init -backend=false && grep -A2 'hashicorp/helm' .terraform.lock.hcl
```

```
provider "registry.terraform.io/hashicorp/helm" {
  version     = "3.3.0"
  constraints = ">= 3.0.0, ~> 3.0"
```

A lock fájl változását commitold: így mindenki ugyanazt a provider verziót kapja.

### 1.7 Az AWS Load Balancer Controller modul

**Mit és miért.** A controller figyeli a `type: LoadBalancer` Service-eket (és az Ingresseket, ha `alb`
osztályúak), és létrehozza hozzájuk az AWS load balancert, a target groupot, a listenert, és regisztrálja a
targeteket. Itt egyetlen Service-t kezel: a Traefikét, és abból NLB-t csinál. A modulban:

- **IRSA szerep** (`aws_iam_role`), a trust policyban két feltétellel:
  - `sub = system:serviceaccount:kube-system:aws-load-balancer-controller`: csak ez a ServiceAccount
    veheti fel a szerepet, más pod nem;
  - `aud = sts.amazonaws.com`: a token az STS-nek szól (nem egy másik szolgáltatásnak kiadott token).
- **A hivatalos IAM policy** (`iam_policy.json`), a chart verziójához illő controller verzióból. A 3.x óta a
  chart és a controller verziója megegyezik (chart 3.6.2 = controller v3.6.2). Egy `precondition` megállítja
  a plant, ha a fájl nem érvényes policy.
- **Helm release** rögzített chart verzióval. A `region` és a `vpcId` megadása azért kell, mert a pod nem
  éri el az IMDS-t (1.5). A ServiceAccountra a chart teszi rá az `eks.amazonaws.com/role-arn` annotációt.

**Hol.** Új könyvtár: `terraform/modules/lb-controller/`.

A policy letöltése és ellenőrzése:

```bash
curl -fsSL -o terraform/modules/lb-controller/iam_policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.2/docs/install/iam_policy.json
python3 -c "import json; json.load(open('terraform/modules/lb-controller/iam_policy.json')); print('valid json')"
sha256sum terraform/modules/lb-controller/iam_policy.json
# 16f232c9d9f79366fe949c4550ad517a202380058a9e48d45a4e215044a20a6a
git show fcd3e6c:terraform/modules/lb-controller/iam_policy.json | diff - terraform/modules/lb-controller/iam_policy.json && echo IDENTICAL
```

A v3.6.2-es policy byte-ra azonos azzal, ami a template-ben volt (`IDENTICAL`). A policy 251 sor, ezért itt
nem másolom be: a fenti `curl` pontosan ezt a fájlt adja.

`terraform/modules/lb-controller/main.tf`:

```hcl
locals {
  policy_file = "${path.module}/iam_policy.json"
}

# Trust policy (IRSA): a szerepet csak egy OIDC tokennel lehet felvenni, és csak akkor,
# ha a token a mi clusterünk kube-system/aws-load-balancer-controller ServiceAccountjáé
# (sub feltétel), és az STS-nek szól (aud feltétel). Más pod nem kapja meg ezeket a jogokat.
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# IAM szerep a controllernek: ezzel hozza létre és kezeli az NLB-t, a target groupokat és a
# target regisztrációkat.
resource "aws_iam_role" "this" {
  name               = "${var.cluster_name}-aws-lbc"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# A controller hivatalos IAM policyja, a modul mellett lévő iam_policy.json fájlból
# (a chart verziójával egyező controller verzió docs/install/iam_policy.json fájlja).
resource "aws_iam_policy" "this" {
  name        = "${var.cluster_name}-AWSLoadBalancerControllerIAMPolicy"
  description = "AWS Load Balancer Controller (${var.cluster_name})"
  policy      = file(local.policy_file)

  # Védőháló: ha az iam_policy.json nem érvényes IAM policy (pl. üres, vagy valaki egy helyőrzőt
  # tett a helyére), a plan érthető hibaüzenettel álljon meg, ne az AWS API-tól jöjjön homályos hiba apply közben.
  lifecycle {
    precondition {
      condition     = can(jsondecode(file(local.policy_file)).Statement)
      error_message = "A modules/lb-controller/iam_policy.json nem érvényes IAM policy. Töltsd le a hivatalos policyt a controller verziójához illő verzióval (a 3.x óta a chart és a controller verziója megegyezik)."
    }
  }
}

# A policy csatolása a controller szerepéhez.
resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}

# Az AWS Load Balancer Controller telepítése Helm charttal (Helm provider 3.x: a set lista).
# A chart létrehozza a ServiceAccountot, és ráteszi a role-arn annotációt (IRSA). Az EKS egy
# webhookja ebből tudja, hogy a podba be kell tenni a ServiceAccount tokent és a szerep ARN-jét,
# amivel az AWS SDK felveszi a szerepet. (A webhook neve pod-identity-webhook, de ez az IRSA része,
# nem azonos az újabb "EKS Pod Identity" funkcióval.)
# A wait (alapból true) miatt az apply csak akkor lép tovább, ha a controller podjai Ready-k:
# a Traefik release ezután jön, és a LoadBalancer Service-e már átmegy a controller webhookján.
resource "helm_release" "this" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_version
  namespace  = var.namespace

  set = [
    {
      name  = "clusterName"
      value = var.cluster_name
    },
    {
      name  = "region"
      value = var.region
    },
    {
      name  = "vpcId"
      value = var.vpc_id
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = var.service_account_name
    },
    {
      # A pontokat escape-elni kell, különben a Helm a kulcsot beágyazott útvonalnak venné
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.this.arn
    },
  ]

  # A controller csak akkor induljon, ha a szerepén már rajta van a policy
  depends_on = [aws_iam_role_policy_attachment.this]
}
```

`terraform/modules/lb-controller/variables.tf`:

```hcl
variable "cluster_name" {
  description = "Az EKS cluster neve (a controller ezzel tageli/keresi az erőforrásait)"
  type        = string
}

variable "region" {
  description = "AWS régió (megadjuk, hogy a controllernek ne kelljen az IMDS-ből kiolvasnia)"
  type        = string
}

variable "vpc_id" {
  description = "A VPC azonosítója (megadjuk, hogy a controllernek ne kelljen az IMDS-ből kiolvasnia)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "Az IAM OIDC provider ARN-je (az eks modul kimenete)"
  type        = string
}

variable "oidc_provider_url" {
  description = "Az OIDC kibocsátó címe https:// nélkül (az eks modul kimenete)"
  type        = string
}

variable "namespace" {
  description = "Ebbe a namespace-be települ a controller"
  type        = string
  default     = "kube-system"
}

variable "service_account_name" {
  description = "A controller ServiceAccountjának neve; csak ez veheti fel az IAM szerepet"
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "chart_version" {
  description = "Az aws-load-balancer-controller Helm chart verziója; az iam_policy.json ehhez illeszkedjen"
  type        = string
}
```

`terraform/modules/lb-controller/outputs.tf`:

```hcl
output "iam_role_arn" {
  description = "A controller IRSA szerepének ARN-je"
  value       = aws_iam_role.this.arn
}

output "helm_release_version" {
  description = "A telepített chart verziója"
  value       = helm_release.this.version
}
```

`terraform/modules/lb-controller/versions.tf`:

```hcl
# Minimális provider verziók; a pontos rögzítés a rootban van. Provider blokk itt NINCS
# (a Helm provider is a rootban van konfigurálva, a modul azt örökli).
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0"
    }
  }
}
```

**Ellenőrzés.** `helm show values eks/aws-load-balancer-controller --version 3.6.2 | grep -nE '^(clusterName|region|vpcId):'`
→ mindhárom kulcs létezik a chartban (a `set` nevek helyesek). Apply után:
`kubectl -n kube-system get deploy aws-load-balancer-controller` → `READY 2/2`, és
`kubectl -n kube-system get sa aws-load-balancer-controller -o jsonpath='{.metadata.annotations}'` → benne a role ARN.

### 1.8 A Traefik modul

**Mit és miért.** A Traefik Helm release-e Terraformból települ, saját modulban. A chart létrehozza:

- a **Deploymentet** (2 replika, tfvars-ból, legalább 2: egy pod vagy egy node kiesése ne állítsa le a
  forgalmat) és egy **PodDisruptionBudgetet** (`maxUnavailable: 1`: node csere közben is marad egy pod);
- a **LoadBalancer Service-t** az NLB annotációkkal. Ezeket nem a Traefik, hanem az LB Controller olvassa.
  Az NLB SG ID-ja **közvetlenül a Terraformból** kerül az annotációba, ezért a `render.sh`-nak nem kell
  patchelnie;
- az **IngressClass**-t (`traefik`, nem alapértelmezett: minden Ingress mondja ki az `ingressClassName`-et);
- az RBAC-ot (a Traefiknek olvasnia kell az Ingress, Service, EndpointSlice objektumokat) és a Traefik
  CRD-ket (pl. `Middleware`, a 6. fejezethez kell).

A chart értékei közül a nem triviálisak:

| Érték | Miért |
|---|---|
| `providers.kubernetesIngress.strictPrefixMatching: true` | A Kubernetes spec szerinti `Prefix` illesztés útvonal elemenként: a `/api/sa` illeszkedik a `/api/sa` és a `/api/sa/x` útvonalra, de a `/api/saxyz`-re nem. Alapból a Traefik szövegesen illesztene. |
| `ports.web.port`, `ports.traefik.port` | A konténer portjai a root `ingress_controller_ports`-ból (8000, 8080), ugyanonnan, ahonnan az SG szabályok. |
| `ports.websecure.expose.default: false` | Nincs TLS, a 443-at ne tegye a Service-re. |
| `accessLog.enabled: true` | Kérésenkénti napló a kliens IP-vel: így látszik a teszteléskor, hogy a kliens IP megmaradt. |
| `service.spec.allocateLoadBalancerNodePorts: false` | `ip` targetnél nincs szükség NodePortra. |
| `forwardedHeaders.trustedIPs` | **Nincs beállítva** (üres): a kliens nem hamisíthat `X-Forwarded-For`-t. |

A `values = [yamlencode(...)]` forma azért jobb itt a `set` listánál, mert a pontokat és perjeleket
tartalmazó annotáció kulcsokat nem kell escape-elni, és az értékek típusosak maradnak.

**A `depends_on` szerepe** (a rootban, 1.9): létrehozáskor a Traefik Service csak akkor jöhet létre, ha az LB
Controller és a webhookja már fut. Lebontáskor a sorrend megfordul: **előbb** a Traefik release törlődik. A
Helm provider uninstall közben vár (`wait`, alapból `true`; a provider forrása szerint
`uninstall.Wait = state.Wait`), amíg a Service ténylegesen eltűnik. A Service-en az LB Controller
finalizere (`service.k8s.aws/resources`) van, ezt a controller csak azután veszi le, hogy az NLB-t és a
target groupot törölte. Mivel az LB Controller modul csak a Traefik modul után törlődhet, a controller ekkor
még fut. Fordított sorrendben az NLB gazdátlanul ott maradna, és a destroy elakadna az NLB SG-n
(`DependencyViolation`) és a VPC-n.

**Hol.** Új könyvtár: `terraform/modules/traefik/`.

`terraform/modules/traefik/main.tf`:

```hcl
locals {
  # A Traefik Service-ének annotációi. Ezeket NEM a Traefik olvassa, hanem az AWS Load
  # Balancer Controller: ezekből tudja, milyen NLB-t hozzon létre a LoadBalancer Service-hez.
  service_annotations = {
    # Az AWS Load Balancer Controller kezelje (nem a régi, beépített cloud provider), és NLB legyen
    "service.beta.kubernetes.io/aws-load-balancer-type" = "external"
    # Publikus legyen (alapból internal lenne!), a kubernetes.io/role/elb taggelt subnetekben
    "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
    # ip: az NLB közvetlenül a Traefik podok IP-jére küld (nincs NodePort, nincs kube-proxy ugrás)
    "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
    # Fix név: a teardown.sh név szerint várja meg a törlését. Ára: a csere (pl. scheme
    # változás) csak a régi NLB törlése után mehet, mert két NLB nem lehet azonos névvel.
    "service.beta.kubernetes.io/aws-load-balancer-name" = var.load_balancer_name
    # A Terraformban létrehozott NLB security group, közvetlenül (nem kell a manifestet patchelni)
    "service.beta.kubernetes.io/aws-load-balancer-security-groups" = var.nlb_security_group_id
    # A node SG szabályait a Terraform kezeli (node_from_nlb); ha a controller is felvenné,
    # az AWS duplikált szabályként utasítaná el
    "service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules" = "false"
    # ip targetnél a kliens IP megőrzése alapból KI van kapcsolva; így a Traefik a valódi
    # kliens IP-t látja forrásként, és azt írja az X-Forwarded-For fejlécbe
    "service.beta.kubernetes.io/aws-load-balancer-target-group-attributes" = "preserve_client_ip.enabled=true"
    # HTTP health check a Traefik /ping végpontjára (a "traefik" entrypoint portján): a TCP
    # check akkor is zöld lenne, ha a port nyitva van, de a Traefik még nem kész
    "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol" = "http"
    "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"     = tostring(var.ports["ping"])
    "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"     = "/ping"
  }

  # A chart értékei (helm show values traefik/traefik --version <verzió>). A yamlencode miatt
  # a pontokat tartalmazó annotáció kulcsokat nem kell escape-elni (a set listával ellentétben).
  helm_values = {
    deployment = {
      replicas = var.replicas
    }

    # Node csere / leürítés közben is maradjon legalább egy futó Traefik pod
    podDisruptionBudget = {
      enabled        = true
      maxUnavailable = 1
    }

    # Az IngressClass: az Ingress objektumok az ingressClassName mezővel erre hivatkoznak.
    # Nem alapértelmezett, így minden Ingressnek ki kell mondania, melyik controllerhez tartozik.
    ingressClass = {
      enabled        = true
      isDefaultClass = false
      name           = var.ingress_class_name
    }

    providers = {
      kubernetesIngress = {
        # A Kubernetes spec szerinti Prefix illesztés útvonal elemenként: /api/sa illeszkedik a
        # /api/sa és /api/sa/x útvonalra, de a /api/saxyz-re nem (alapból a Traefik szövegesen illesztene)
        strictPrefixMatching = true
      }
    }

    # Kérésenkénti napló (kliens IP, útvonal, státusz, melyik backend): a teszteléshez és a hibakereséshez
    accessLog = {
      enabled = true
    }

    ports = {
      # A "traefik" entrypoint: itt van a /ping (readiness, liveness és az NLB health check).
      # Nincs kitéve a Service-en (expose.default = false a chart alapértéke).
      traefik = {
        port = var.ports["ping"]
      }
      # A "web" entrypoint: ide jön az NLB forgalma; a Service 80-as portja erre mutat.
      # A forwardedHeaders.trustedIPs üres (alapérték): a klienstől jövő X-Forwarded-* fejléceket
      # a Traefik nem fogadja el, hanem a valódi forrás IP-vel állítja be.
      web = {
        port = var.ports["web"]
      }
      # HTTPS-t most nem szolgálunk ki (nincs TLS), ezért nem kerül a Service-re
      websecure = {
        expose = {
          default = false
        }
      }
    }

    resources = {
      requests = {
        cpu    = "100m"
        memory = "128Mi"
      }
      limits = {
        memory = "256Mi"
      }
    }

    service = {
      annotations = local.service_annotations
      spec = {
        # ip targetnél az NLB nem használ NodePortot, ezért ne is foglaljon a Service
        allocateLoadBalancerNodePorts = false
      }
    }
  }
}

# A Traefik Ingress controller telepítése Helm charttal. A chart létrehozza a Deploymentet,
# a LoadBalancer Service-t (ebből csinál NLB-t az AWS Load Balancer Controller), az
# IngressClass-t, a PodDisruptionBudgetet, az RBAC-ot és a Traefik CRD-ket (pl. Middleware).
# Lebontáskor a wait (alapból true) miatt a Helm megvárja, amíg a Service ténylegesen törlődik,
# vagyis amíg a controller a finalizere előtt az NLB-t is törli.
resource "helm_release" "this" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  values = [yamlencode(local.helm_values)]
}
```

`terraform/modules/traefik/variables.tf`:

```hcl
variable "chart_version" {
  description = "A traefik Helm chart rögzített verziója (helm search repo traefik/traefik --versions)"
  type        = string
}

variable "namespace" {
  description = "Ebbe a namespace-be települ a Traefik (a release hozza létre)"
  type        = string
  default     = "traefik"
}

variable "replicas" {
  description = "A Traefik podok száma; legalább 2, hogy egy pod vagy node kiesése ne állítsa le a forgalmat"
  type        = number

  validation {
    condition     = var.replicas >= 2
    error_message = "Legalább 2 replika kell."
  }
}

variable "ingress_class_name" {
  description = "Az IngressClass neve; az Ingress objektumok ingressClassName mezője erre hivatkozik"
  type        = string
  default     = "traefik"
}

variable "ports" {
  description = "A Traefik konténer portjai: web (forgalom az NLB felől) és ping (health check); ugyanezekre nyit szabályt a node SG"
  type        = map(number)

  validation {
    condition     = alltrue([for k in ["web", "ping"] : contains(keys(var.ports), k)])
    error_message = "A ports térképben kell egy \"web\" és egy \"ping\" kulcs."
  }
}

variable "load_balancer_name" {
  description = "Az NLB fix neve (aws-load-balancer-name annotáció); legfeljebb 32 karakter"
  type        = string

  validation {
    condition     = length(var.load_balancer_name) <= 32 && can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]$", var.load_balancer_name))
    error_message = "Az NLB neve legfeljebb 32 karakter, csak betű, szám és kötőjel, és nem kezdődhet/végződhet kötőjellel."
  }
}

variable "nlb_security_group_id" {
  description = "Az NLB security groupja (az eks modul kimenete); a Service annotációjába kerül"
  type        = string
}
```

`terraform/modules/traefik/outputs.tf`:

```hcl
output "namespace" {
  description = "A Traefik namespace-e"
  value       = helm_release.this.namespace
}

output "ingress_class_name" {
  description = "Az IngressClass neve (az Ingress objektumok ingressClassName mezőjéhez)"
  value       = var.ingress_class_name
}

output "load_balancer_name" {
  description = "Az NLB neve (a teardown.sh ezzel várja meg a törlését)"
  value       = var.load_balancer_name
}
```

`terraform/modules/traefik/versions.tf`:

```hcl
# Minimális provider verzió; a pontos rögzítés a rootban van. Provider blokk itt NINCS
# (a Helm provider a rootban van konfigurálva, a modul azt örökli).
terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0"
    }
  }
}
```

**Ellenőrzés.** Az értékek kulcsai léteznek a chartban:

```bash
helm repo add traefik https://traefik.github.io/charts && helm repo update traefik
helm show values traefik/traefik --version 42.3.1 | grep -nE '^(deployment|podDisruptionBudget|ingressClass|providers|accessLog|ports|resources|service):'
```

A tényleges renderelés (a Terraform értékeivel) az 1.11-ben van.

### 1.9 A root bekötése

**Mit és miért.** A root hívja meg a két új modult, adja a portokat és az NLB nevét (`locals.tf`), az új
változókat (`variables.tf`, tfvars) és a Helm providert (1.6).

`terraform/locals.tf`, teljes:

```hcl
# Számított és közös értékek, amelyeket a modulhívások használnak.
locals {
  # A két alkalmazás neve: ebből lesznek az ECR repók.
  # A scripts/build-push.sh ugyanezeket a neveket használja (külön, a saját ciklusában).
  services = ["service-a", "service-b"]

  # A Traefik konténer portjai (név => port), EGY helyen: ebből kapja a Traefik modul a
  # Helm értékeket, az eks modul pedig a node SG és az NLB SG szabályait. Ha itt változik,
  # mindkét oldal együtt változik. (A chart alapértékei: web 8000, traefik/ping 8080.)
  ingress_controller_ports = {
    web  = 8000 # forgalom az NLB felől
    ping = 8080 # NLB health check és a pod probe-ok (/ping)
  }

  # Az NLB fix neve (legfeljebb 32 karakter; a traefik modul ellenőrzi)
  nlb_name = "${var.cluster_name}-nlb"
}
```

`terraform/main.tf`, teljes (az eks modulhívás két új sort kapott, a végére jött a két új modul):

```hcl
# A modulok meghívása. A sorrend az olvashatóságot szolgálja; azt, hogy mi mikor jön létre,
# a Terraform a hivatkozásokból (függőségekből) dönti el.

# ECR repók a két alkalmazás image-ének (for_each a szolgáltatás nevével).
# A repók neve <cluster_name>/<szolgáltatás>, pl. szino-alb-practice/service-a.
# Független a többitől, ezért a Terraform a VPC-vel párhuzamosan hozza létre.
module "ecr" {
  source = "./modules/ecr"

  name_prefix          = var.cluster_name
  repository_names     = local.services
  image_tag_mutability = var.ecr_image_tag_mutability
  force_delete         = var.ecr_force_delete
}

# Hálózat: VPC, publikus és privát subnetek AZ-nként (a tfvars subnets térképéből),
# internet és NAT gateway, route táblák.
module "vpc" {
  source = "./modules/vpc"

  name     = var.cluster_name
  vpc_cidr = var.vpc_cidr
  subnets  = var.subnets
}

# EKS cluster: IAM szerepek, security groupok (az NLB-é is), cluster, addonok,
# managed node group, OIDC provider és admin access entry.
module "eks" {
  source = "./modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids # a control plane ENI-k és a node-ok is a privát subnetekben

  node_instance_types = var.node_instance_types
  node_ami_type       = var.node_ami_type
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  nlb_ingress_cidrs            = var.nlb_ingress_cidrs
  nlb_target_ports             = local.ingress_controller_ports

  # Aki a Terraformot futtatja (IAM user), cluster admin lesz
  cluster_admin_principal_arns = [data.aws_caller_identity.current.arn]
}

# AWS Load Balancer Controller: IRSA szerep + Helm release. Ez hozza létre az NLB-t
# a Traefik LoadBalancer Service-e alapján.
module "lb_controller" {
  source = "./modules/lb-controller"

  cluster_name      = module.eks.cluster_name
  region            = var.region
  vpc_id            = module.vpc.vpc_id
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  chart_version     = var.lb_controller_chart_version

  # A Helm release csak akkor induljon, ha az EKS modul MINDEN eleme kész: a node group
  # (különben a controller podjai nem tudnak elindulni), az admin access entry (különben a
  # Helm provider nem jogosult telepíteni) és a 9443-as webhook szabály.
  depends_on = [module.eks]
}

# Traefik Ingress controller: Deployment + LoadBalancer Service (NLB annotációkkal) + IngressClass.
module "traefik" {
  source = "./modules/traefik"

  chart_version         = var.traefik_chart_version
  replicas              = var.ingress_controller_replicas
  ports                 = local.ingress_controller_ports
  load_balancer_name    = local.nlb_name
  nlb_security_group_id = module.eks.nlb_security_group_id

  # Létrehozáskor: a Service csak akkor jöhet létre, ha az LB Controller (és a webhookja) fut.
  # Lebontáskor (fordított sorrend): ELŐBB a Traefik release törlődik, és amíg a Helm a Service
  # törlésére vár, az LB Controller még fut, így le tudja bontani az NLB-t. Ha az LB Controller
  # törlődne előbb, az NLB gazdátlanul ott maradna, és a destroy elakadna az NLB SG-n és a VPC-n.
  depends_on = [module.lb_controller]
}
```

`terraform/variables.tf`, új változók az `ecr_image_tag_mutability` elé:

```hcl
variable "nlb_ingress_cidrs" {
  description = "Honnan érhető el az NLB a 80-as porton (CIDR lista); nyilvános szolgáltatásnál [\"0.0.0.0/0\"]"
  type        = list(string)

  validation {
    condition     = length(var.nlb_ingress_cidrs) > 0 && alltrue([for c in var.nlb_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "Legalább egy érvényes CIDR kell (pl. 1.2.3.4/32)."
  }
}

variable "ingress_controller_replicas" {
  description = "A Traefik podok száma (legalább 2)"
  type        = number
}

variable "lb_controller_chart_version" {
  description = "Az aws-load-balancer-controller Helm chart verziója; a 3.x óta megegyezik a controller verziójával, és a modules/lb-controller/iam_policy.json-nak ehhez kell illeszkednie. Ennek marad alapértéke, mert a policy JSON-hoz kötődik, vagyis a kód része."
  type        = string
  default     = "3.6.2"
}

variable "traefik_chart_version" {
  description = "A traefik Helm chart verziója (a 42.3.1 a Traefik v3.7.17-et telepíti; a 2026-11-10-i 42.3.2 helyett, mert egy friss kiadásnak érdemes egy-két hetet hagyni). Ennek marad alapértéke, mert a Helm értékek (modules/traefik) ehhez a chart verzióhoz készültek, vagyis a kód része."
  type        = string
  default     = "42.3.1"
}
```

A két chart verziónak **van** alapértéke, a környezeti értékeknek (`nlb_ingress_cidrs`, replikaszám) nincs.
A chart verzió a kódhoz tartozik: az `iam_policy.json` és a Traefik Helm értékei egy adott chart verzióhoz
készültek, ezért ezek együtt változnak, nem környezetenként.

`terraform/terraform.tfvars.example`, új sorok a `cluster_endpoint_public_access_cidrs` után:

```hcl
# Honnan érhető el az NLB (a 80-as port); nyilvános szolgáltatásnál az egész internet,
# teszteléshez szűkíthető a saját IP-dre, pl. ["1.2.3.4/32"]
nlb_ingress_cidrs = ["0.0.0.0/0"]

# A Traefik Ingress controller podjainak száma (legalább 2)
ingress_controller_replicas = 2
```

### 1.10 Outputok

**Mit és miért.** A `teardown.sh` az NLB nevét a Terraformtól kérdezi (`nlb_name`), az SG ID és az IngressClass
neve a teszteléshez és a hibakereséshez kell.

`terraform/outputs.tf`, a fájl végére:

```hcl
output "nlb_name" {
  description = "Az NLB neve (a teardown.sh ezzel várja meg a törlését; aws elbv2 describe-load-balancers --names)"
  value       = module.traefik.load_balancer_name
}

output "nlb_security_group_id" {
  description = "Az NLB security groupja (a Traefik Service annotációjában is ez van)"
  value       = module.eks.nlb_security_group_id
}

output "ingress_class_name" {
  description = "Az IngressClass neve (a k8s/base/ingress.yaml ingressClassName mezője)"
  value       = module.traefik.ingress_class_name
}
```

### 1.11 Ellenőrzés: init, fmt, validate és a Helm értékek renderelése

```bash
cd terraform
terraform init -backend=false
terraform fmt -check -recursive ; echo "exit=$?"
terraform validate
```

Várt kimenet: az init `Installed hashicorp/helm v3.3.0`, az fmt `exit=0` (üres kimenet), a validate
`Success! The configuration is valid.`

A Traefik Service annotációit cluster nélkül is ellenőrizni lehet: a modul `local.helm_values` értékét
`terraform console`-lal kiolvassuk (csak változókra hivatkozik, ezért nem kell hozzá state), és pontosan
ezzel futtatjuk a `helm template`-et. A modult egy ideiglenes könyvtárba másoljuk, hogy a `.terraform` és a
lock fájl ne a repóba kerüljön:

```bash
TMP=$(mktemp -d) && cp -r terraform/modules/traefik "$TMP/mod" && cd "$TMP/mod"
terraform init -backend=false >/dev/null
echo 'jsonencode(local.helm_values)' | terraform console \
  -var chart_version=42.3.1 -var replicas=2 -var 'ports={web=8000,ping=8080}' \
  -var load_balancer_name=szino-alb-practice-nlb -var nlb_security_group_id=sg-0123456789abcdef0 \
  | python3 -c "import sys,json,yaml; print(yaml.safe_dump(json.loads(json.loads(sys.stdin.read())), sort_keys=False))" \
  > values.yaml
helm template traefik traefik/traefik --version 42.3.1 -n traefik -f values.yaml > render.yaml
grep -E '^kind:' render.yaml | sort | uniq -c
awk '/^kind: Service$/,/^---/' render.yaml
cd - && rm -rf "$TMP"
```

Várt kimenet (részlet):

```
      1 kind: ClusterRole
      1 kind: ClusterRoleBinding
      1 kind: Deployment
      1 kind: IngressClass
      1 kind: PodDisruptionBudget
      1 kind: Service
      1 kind: ServiceAccount
```

```yaml
kind: Service
metadata:
  name: traefik
  namespace: traefik
  labels:
    app.kubernetes.io/name: traefik
    app.kubernetes.io/instance: traefik-traefik
    app.kubernetes.io/version: "v3.7.17"
    helm.sh/chart: traefik-42.3.1
    app.kubernetes.io/managed-by: Helm
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: /ping
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "8080"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: http
    service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules: "false"
    service.beta.kubernetes.io/aws-load-balancer-name: szino-alb-practice-nlb
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-security-groups: sg-0123456789abcdef0
    service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: preserve_client_ip.enabled=true
    service.beta.kubernetes.io/aws-load-balancer-type: external
spec:
  allocateLoadBalancerNodePorts: false
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: traefik
    app.kubernetes.io/instance: traefik-traefik
  ports:
  - port: 80
    name: web
    targetPort: web
    protocol: TCP
```

---

## 2. Kubernetes

### 2.1 Az Ingress objektum

**Mit és miért.** A régi `default.conf` `location /api/sa { proxy_pass http://service-a...; }` blokkjai helyett
egy szabványos `Ingress` írja le az útválasztást. A Traefik a Kubernetes API-ból figyeli: amint az objektum
létrejön vagy módosul, újratölti a routereit, nincs ConfigMap, nincs pod újraindítás.

- `ingressClassName: traefik`: ez köti a Traefikhez. Mivel az IngressClass nem alapértelmezett, enélkül
  egyik controller sem foglalkozna vele.
- `pathType: Prefix`: a `/api/sa` és minden alatta. A `strictPrefixMatching` miatt útvonal elemenként.
- A backend a **Service portja** (80), nem a konténeré (8080). A Traefik a Service EndpointSlice-aiból veszi
  a pod IP-ket, és a `targetPort` alapján a 8080-ra küld.
- **Nincs útvonal átírás**: a Flask appok a teljes útvonalon (`/api/sa`) válaszolnak, ezért a kérés változatlanul
  megy tovább (ahogy a régi `proxy_pass` is perjel nélkül).
- **Nincs `host`**: bármilyen Host fejlécre érvényes, így az NLB DNS nevével közvetlenül tesztelhető.
- A régi `location /` → 404 helyett a Traefik maga ad 404-et (`404 page not found`) minden olyan kérésre,
  amire nincs szabály. A `/healthz` a proxyn már nincs: a Traefik egészségét az NLB a `/ping`-en nézi.

**Hol.** Új fájl: `k8s/base/ingress.yaml`.

```yaml
# Az útválasztás a régi nginx ConfigMap location blokkjai helyett. Ezt az objektumot a Traefik
# olvassa (az ingressClassName alapján az övé), és a szabályokból állítja össze a saját
# routereit; a podok IP-jeit közvetlenül a Service-ek EndpointSlice-aiból veszi.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo
  namespace: demo
spec:
  # Az IngressClass neve (a Terraform traefik modulja hozza létre, nem alapértelmezett):
  # enélkül egyik controller sem venné magára az Ingresst
  ingressClassName: traefik
  rules:
    # Nincs host mező: bármilyen Host fejléccel (pl. az NLB DNS nevével) érkező kérésre érvényes
    - http:
        paths:
          # Prefix: /api/sa és minden alatta lévő útvonal (/api/sa/x), de /api/saxyz nem.
          # Átírás nincs: a teljes útvonal (/api/sa) megy tovább, és a Flask app pont erre figyel.
          - path: /api/sa
            pathType: Prefix
            backend:
              service:
                name: service-a
                port:
                  number: 80 # a Service portja, NEM a konténeré (8080; azt a targetPort köti össze)
          - path: /api/sb
            pathType: Prefix
            backend:
              service:
                name: service-b
                port:
                  number: 80
```

### 2.2 A kustomization

**Hol.** `k8s/base/kustomization.yaml`, a `resources` lista végére.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - service-a.yaml
  - service-b.yaml
  - ingress.yaml
```

**Ellenőrzés.**

```bash
kubectl kustomize k8s/base | grep -E '^kind:'
```

```
kind: Namespace
kind: Service
kind: Service
kind: Deployment
kind: Deployment
kind: Ingress
```

---

## 3. Scriptek

### 3.1 `render.sh`: csak az image csere

**Mit és miért.** Régen a generált overlay egy patch-csel írta a Service annotációjába az NLB SG ID-ját, mert az
ID minden apply után más, és a manifest nem tudott róla. Most a Traefik Service-t a Terraform hozza létre, és
az annotációba közvetlenül a Terraform írja az ID-t. A `render.sh` így csak az image címeket cseréli
(ECR cím + tag). Változás: csak a fejléc komment (és a fájl végi sortörés).

**Hol.** `scripts/render.sh`, a fejléc komment.

```bash
#!/usr/bin/env bash
# Legenerálja a helyi overlay-t (k8s/overlays/local/kustomization.yaml) a Terraform
# kimenetéből. A base (k8s/base/) érintetlen marad, ezért a szkript akárhányszor futtatható.
# Csak az image címeket cseréli: az NLB security group ID-ját már a Terraform írja közvetlenül
# a Traefik Service annotációjába (modules/traefik), ezért itt nincs patch.
# Használat: ./scripts/render.sh 1.0.0
set -euo pipefail

TAG="${1:-1.0.0}"
REGION="$(terraform -chdir=terraform output -raw region)"
CLUSTER="$(terraform -chdir=terraform output -raw cluster_name)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
# A repók címe: <regiszter>/<cluster_name>/<szolgáltatás>
REPO_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${CLUSTER}"

OVERLAY_DIR="k8s/overlays/local"
mkdir -p "$OVERLAY_DIR"

# A "cat >" minden futtatáskor teljesen felülírja a fájlt, így mindig az aktuális
# értékek kerülnek bele. A heredoc-ban a bash behelyettesíti a ${...} változókat.
cat > "${OVERLAY_DIR}/kustomization.yaml" <<EOF
# GENERÁLT FÁJL, ne szerkeszd kézzel: a scripts/render.sh írja. Nincs a gitben.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# A közös manifestek, környezetfüggő érték nélkül
resources:
- ../../base

# Az "image: service-a" és "image: service-b" cseréje az ECR címre és a tagre.
# A "name" a Deploymentben lévő image névre illeszkedik, ezért az nem változik.
images:
- name: service-a
  newName: ${REPO_BASE}/service-a
  newTag: "${TAG}"
- name: service-b
  newName: ${REPO_BASE}/service-b
  newTag: "${TAG}"
EOF

echo "Generálva: ${OVERLAY_DIR}/kustomization.yaml (tag: ${TAG})"
echo "Ellenőrzés: kubectl kustomize ${OVERLAY_DIR}"
```

**Ellenőrzés.** `bash -n scripts/render.sh` → üres kimenet.

### 3.2 `teardown.sh`: a helyes lebontási sorrend

**Mit és miért.** Az NLB-t nem a Terraform hozza létre, hanem az LB Controller, ezért a Terraform nem tud róla.
A sorrend:

1. `kubectl delete -k k8s/base`: az appok, az Ingress, a `demo` namespace.
2. `terraform destroy -target=module.traefik`: csak a Traefik release (ettől semmi nem függ). A Helm megvárja
   a Service törlését, vagyis azt, hogy a controller törölje az NLB-t.
3. Biztonsági várakozás: az NLB név szerint (`aws elbv2 describe-load-balancers --names`) legfeljebb 5 percig.
   A fix név miatt ez egyértelmű, a megosztott accountban sem keveredik más projekt NLB-jével.
4. A teljes `terraform destroy`: LB Controller, EKS, VPC, NAT, ECR, IAM, security groupok.
5. A meglévő költségellenőrzés.

Ha a cluster már nem létezik, a script nem tud a controllerrel NLB-t töröltetni: figyelmeztet, és ha az NLB
még megvan, kilép (kézi törlés kell), ha nincs, kiírja a `terraform state rm` parancsot a két Helm release-re,
mert ezeket a Terraform cluster nélkül nem tudja frissíteni.

**Hol.** `scripts/teardown.sh`, teljes új tartalom:

```bash
#!/usr/bin/env bash
# Mindent lebont, a helyes sorrendben, és a végén ellenőrzi, hogy nem maradt-e
# fizetős erőforrás. Használat (a projekt gyökeréből): ./scripts/teardown.sh
#
# A sorrend lényege: az NLB-t nem a Terraform hozza létre, hanem az AWS Load Balancer
# Controller (a Traefik LoadBalancer Service-éből). Ezért ELŐBB a Traefik release-t kell
# törölni, amíg a controller még fut, és MEG KELL VÁRNI, hogy az NLB eltűnjön. Ha a cluster
# (vagy a controller) előbb tűnne el, az NLB gazdátlanul ott maradna (és fizetni kellene érte),
# a terraform destroy pedig elakadna az NLB security groupján és a VPC-n.
set -euo pipefail

TF_DIR="terraform"

# A régiót, a cluster és az NLB nevét a Terraform kimenetéből vesszük, mint a többi szkript.
# Ha nincs state (pl. már le van bontva), nincs mit tenni.
if ! REGION="$(terraform -chdir="$TF_DIR" output -raw region 2>/dev/null)"; then
  echo "Nincs Terraform kimenet (üres a state?). Valószínűleg már minden le van bontva."
  exit 0
fi
CLUSTER="$(terraform -chdir="$TF_DIR" output -raw cluster_name)"
NLB_NAME="$(terraform -chdir="$TF_DIR" output -raw nlb_name)"

echo "Régió: ${REGION}, cluster: ${CLUSTER}, NLB: ${NLB_NAME}"

# Létezik-e még az NLB? (A describe hibával tér vissza, ha nincs ilyen nevű.)
nlb_exists() {
  aws elbv2 describe-load-balancers --region "$REGION" --names "$NLB_NAME" >/dev/null 2>&1
}

if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

  # ---------- 1. Az alkalmazás manifestjei (Deploymentek, Service-ek, Ingress, namespace) ----------
  # --wait: csak akkor tér vissza, amikor az erőforrások ténylegesen törlődtek.
  kubectl delete -k k8s/base --ignore-not-found --wait=true --timeout=10m

  # ---------- 2. A Traefik release (ezzel a LoadBalancer Service és így az NLB) ----------
  # Csak a traefik modul (és ami tőle függ: semmi). A Helm a Service törlésére vár; a Service
  # finalizerét a controller csak az NLB törlése után veszi le. Rákérdez, mint a teljes destroy.
  terraform -chdir="$TF_DIR" destroy -target=module.traefik

  # ---------- 3. Biztonsági várakozás: az NLB tényleg eltűnt? ----------
  echo "Várakozás, amíg a(z) ${NLB_NAME} NLB eltűnik..."
  for _ in $(seq 1 30); do
    nlb_exists || break
    echo "  még létezik: ${NLB_NAME}"
    sleep 10
  done
  if nlb_exists; then
    echo "HIBA: az NLB 5 perc után is létezik (${NLB_NAME}). Nézd meg az EC2 konzolban és a controller"
    echo "logjában (kubectl -n kube-system logs deploy/aws-load-balancer-controller); a destroy most elakadna."
    exit 1
  fi
  echo "Az NLB törlődött."
else
  echo "A cluster már nem létezik, a Kubernetes és a Traefik lépés kimarad."
  if nlb_exists; then
    echo "FIGYELEM: az NLB (${NLB_NAME}) még létezik, de nincs controller, ami törölné."
    echo "Töröld kézzel az EC2 konzolban (Load Balancers és a k8s-... target groupok), különben a destroy elakad."
    exit 1
  fi
  echo "Ha a destroy a helm_release-eken akad el (nincs cluster, amihez csatlakozzon), vedd ki őket a state-ből:"
  echo "  terraform -chdir=${TF_DIR} state rm module.traefik.helm_release.this module.lb_controller.helm_release.this"
fi

# ---------- 4. Terraform: minden más (LB Controller, EKS, VPC, NAT, ECR, IAM, security groupok) ----------
# Szándékosan nincs -auto-approve: a Terraform megmutatja, mit töröl, és rákérdez.
terraform -chdir="$TF_DIR" destroy

# ---------- 5. Ellenőrzés: maradt-e fizetős erőforrás? ----------
# A megosztott accountban más projektek erőforrásai is megjelenhetnek; a sajátjaidat a
# névről ismered fel (${CLUSTER}, ${NLB_NAME}).
echo
echo "Ellenőrzés (mindháromnál üres kimenet a jó, vagy legalábbis ne legyen benne a ${CLUSTER} / ${NLB_NAME}):"
echo "- Load balancerek:"
aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerName' --output text
echo "- Futó NAT gatewayek:"
aws ec2 describe-nat-gateways --region "$REGION" --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayId' --output text
echo "- EKS clusterek:"
aws eks list-clusters --region "$REGION" --query 'clusters' --output text
echo "Kész."
```

**Ellenőrzés.**

```bash
for f in scripts/*.sh; do bash -n "$f" && echo "OK $f"; done
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.10.0 scripts/*.sh ; echo "exit=$?"
```

Várt: három `OK`, és a shellcheck üres kimenettel `exit=0`.

---

## 4. Ellenőrzés és teszt

### 4.1 Offline (cluster nélkül)

Lásd 1.11, 2.2, 3.2: `terraform init/fmt/validate`, `helm template` a Terraform értékeivel,
`kubectl kustomize`, `bash -n`, `shellcheck`.

### 4.2 Apply

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # és írd át (név, nlb_ingress_cidrs)
cd terraform && terraform init && terraform plan -out tfplan
```

**A plan várható erőforrásszáma nulláról: 57 to add.**

| Modul | Erőforrás | Db |
|---|---|---|
| ecr | 2 repó | 2 |
| vpc | VPC, IGW, 3 publikus + 3 privát subnet, EIP, NAT, 2 route tábla, 2 route, 6 társítás | 20 |
| eks | cluster szerep + 1 policy csatolás, node szerep + 3 csatolás | 6 |
| eks | cluster, node, **NLB** SG | 3 |
| eks | SG szabályok: `cluster_from_nodes_https`, `cluster_all`, `node_self`, `node_from_cluster` ×3 (443, 10250, **9443**), `node_all`, **`node_from_nlb` ×2**, **`nlb_http` ×1** (egy CIDR), **`nlb_to_nodes` ×2** | 12 |
| eks | cluster, 3 addon, launch template, node group, OIDC provider, access entry + policy association | 9 |
| lb_controller | IAM szerep, IAM policy, csatolás, Helm release | 4 |
| traefik | Helm release | 1 |
| | **összesen** | **57** |

(A data source-ok nem számítanak. Minden további `nlb_ingress_cidrs` elem +1 szabály.) Ha a bejárat nélküli
állapot már fent van, a plan **12 to add, 7 to change**: a 6 subnet és a node SG tagjei helyben változnak.

```bash
terraform apply tfplan
$(terraform output -raw kubeconfig_command)
cd ..
./scripts/build-push.sh 1.0.0
./scripts/render.sh 1.0.0
kubectl apply -k k8s/overlays/local
```

### 4.3 Teszt a kész rendszeren

```bash
kubectl -n traefik get pods,svc                     # 2 Running pod; a Service EXTERNAL-IP oszlopában az NLB DNS neve
kubectl -n demo get ingress                         # CLASS traefik, ADDRESS: az NLB DNS neve
kubectl -n demo get pods,svc                        # 2-2 Running pod
NLB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "$NLB"                                         # szino-alb-practice-nlb-<azonosító>.elb.eu-west-1.amazonaws.com
curl -i "http://$NLB/api/sa"                        # 200, Hello from Service A!
curl -i "http://$NLB/api/sb"                        # 200, Hello from Service B!
curl -i "http://$NLB/nincs-ilyen"                   # 404, 404 page not found (a Traefiktől)
curl -i "http://$NLB/api/saxyz"                     # 404 (strictPrefixMatching)
kubectl -n traefik logs deploy/traefik --tail=20    # access log: az első mező a kliens IP (a te publikus IP-d)
curl -s https://checkip.amazonaws.com               # ezzel vesd össze
```

Az NLB DNS név feloldása és a targetek egészségessé válása 2–3 percig tarthat; addig a curl
`Could not resolve host` vagy timeout hibát adhat. A target group állapota:

```bash
TG=$(aws elbv2 describe-target-groups --load-balancer-arn \
  $(aws elbv2 describe-load-balancers --names szino-alb-practice-nlb --query 'LoadBalancers[0].LoadBalancerArn' --output text) \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output table
# 2 sor: a Traefik podok IP-je, port 8000, healthy
```

### 4.4 Lebontás

```bash
./scripts/teardown.sh
```

Két megerősítést kér (a `-target` destroy és a teljes destroy), a végén a költségellenőrzés.

---

## 5. A régi és az új megoldás összevetése

| Szempont | Régi: nginx DaemonSet + ConfigMap | Új: Traefik + Ingress |
|---|---|---|
| A kérés útja | kliens → NLB → **node NodePort** → kube-proxy → helyi nginx pod (`Local`) → service-a ClusterIP (DNS + kube-proxy) → pod | kliens → NLB → **Traefik pod IP** (közvetlenül) → service-a pod IP (az EndpointSlice-ból, kube-proxy nélkül) |
| Kliens IP | `externalTrafficPolicy: Local` + DaemonSet tartotta meg | `ip` target + `preserve_client_ip`; a Traefik az `X-Forwarded-For`-ba írja |
| Ki dönt az útvonalról | az nginx `default.conf` `location` blokkjai egy ConfigMapben | `Ingress` objektumok, `ingressClassName`-mel |
| Konfiguráció módosítása | ConfigMap szerkesztés, majd a podok újraindítása (az nginx nem tölti újra magától) | `kubectl apply` egy Ingressre; a Traefik másodperceken belül átveszi, újraindítás nélkül |
| Új app felvétele | a központi ConfigMap módosítása (egy fájl, egy gazda) | az app csapata a saját namespace-ében a saját Ingressét hozza létre |
| Több csapat | mindenki ugyanazt a fájlt szerkeszti, ütközések, egy elírás mindenkit leállít | Ingressenként független; a controller összefésüli; RBAC-cal szabályozható, ki hozhat létre Ingresst |
| Skálázás | DaemonSet: annyi pod, ahány node (akkor is, ha nem kell) | Deployment: a replikaszám a terheléshez igazítható, PDB védi |
| Health check | NLB → NodePort (`healthCheckNodePort`) | NLB → pod `:8080/ping` (HTTP) |
| Átírás, fejlécek, egyéb | nginx direktívák kézzel | Traefik `Middleware` (CRD) annotációval hivatkozva |
| Telepítés | Kustomize manifestek (DaemonSet, ConfigMap, Service) | Helm release Terraformból, rögzített chart verzióval |
| NLB SG az annotációban | a `render.sh` patch-elte be | a Terraform írja közvetlenül |
| Lebontás | `kubectl delete` a Service-re, várakozás `k8s-demo-` előtagú LB-re | `terraform destroy -target=module.traefik`, várakozás a fix nevű NLB-re, `depends_on` a sorrendhez |

---

## 6. Gyakorló feladat: service-c

**Feladat.** Adj hozzá egy harmadik appot, amely a `/api/sc` útvonalon érhető el. Az app legyen a
`traefik/whoami:v1.12.0` image: ez visszaírja a kapott kérést (útvonal, fejlécek, a pod neve és IP-je),
így minden látszik, ami a proxyn történik. A whoami a **gyökéren** szolgál ki: a `/api/sc`-t vágd le, mielőtt
a kérés hozzá ér. Ne kelljen hozzá ECR (publikus image).

Próbáld meg előbb egyedül; a megoldás lent van.

### Megoldás

`k8s/base/service-c.yaml`:

```yaml
# Gyakorló feladat: harmadik alkalmazás. A traefik/whoami image minden útvonalon válaszol,
# és visszaírja a kapott kérést (útvonal, fejlécek), így látszik az átírás és az X-Forwarded-For.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: service-c
  namespace: demo
  labels:
    app: service-c
spec:
  replicas: 2
  selector:
    matchLabels:
      app: service-c
  template:
    metadata:
      labels:
        app: service-c
    spec:
      securityContext:
        # Az image nem ad meg felhasználót (rootként indulna): számmal adjuk meg a nobody-t
        runAsNonRoot: true
        runAsUser: 65534
      containers:
        - name: app
          image: traefik/whoami:v1.12.0
          # Alapból a 80-as porton figyelne; nem rootként 1024 alatti portot nem nyithat
          args: ["--port=8080"]
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            periodSeconds: 5
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 32Mi
---
apiVersion: v1
kind: Service
metadata:
  name: service-c
  namespace: demo
spec:
  type: ClusterIP
  selector:
    app: service-c
  ports:
    - port: 80
      targetPort: 8080
```

`k8s/base/ingress-service-c.yaml`:

```yaml
# A /api/sc előtag levágása, mielőtt a kérés a service-c-hez ér (a whoami a gyökéren válaszol).
# Traefik CRD (a chart telepíti); az Ingress annotációja <namespace>-<név>@kubernetescrd néven hivatkozik rá.
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: strip-api-sc
  namespace: demo
spec:
  stripPrefix:
    prefixes:
      - /api/sc
---
# KÜLÖN Ingress: a router.middlewares annotáció az Ingress ÖSSZES path-jára vonatkozik. Ha a
# demo Ingressbe kerülne, a /api/sa és /api/sb kérések is átmennének a Middleware-en (ez a
# stripPrefix ott épp nem illeszkedne, de egy általánosabb, pl. /api levágás már elrontaná őket).
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: service-c
  namespace: demo
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: demo-strip-api-sc@kubernetescrd
spec:
  ingressClassName: traefik
  rules:
    - http:
        paths:
          - path: /api/sc
            pathType: Prefix
            backend:
              service:
                name: service-c
                port:
                  number: 80
```

`k8s/base/kustomization.yaml` `resources` listájának végére:

```yaml
  - service-c.yaml
  - ingress-service-c.yaml
```

Ellenőrzés és teszt:

```bash
kubectl kustomize k8s/base | grep -E '^kind:' | sort | uniq -c   # 3 Deployment, 3 Service, 2 Ingress, 1 Middleware
kubectl apply -k k8s/overlays/local
curl -s "http://$NLB/api/sc"           # GET / HTTP/1.1 ... (a whoami a levágott útvonalat látja)
curl -s "http://$NLB/api/sc/barmi"     # GET /barmi HTTP/1.1
curl -s -H 'X-Forwarded-For: 6.6.6.6' "http://$NLB/api/sc" | grep -i x-forwarded-for   # a te IP-d, NEM a 6.6.6.6
curl -s "http://$NLB/api/sa"           # továbbra is Hello from Service A!
```

### Buktatók

1. **`port` és `targetPort`.** Az Ingress a Service **portjára** (80) hivatkozik, a Service `targetPort`-ja
   (8080) a konténerre. Ha az Ingressbe 8080 kerül, a Traefik nem talál ilyen portot a Service-en
   (a Traefik logjában hiba jelzi a hiányzó portot), a router nem jön létre, a kérés 404 lesz. Ha a `targetPort` nem egyezik a konténer
   portjával, a Service-nek nincs működő endpointja, a kérés `502`/`503` lesz.
2. **A konténer portja.** A whoami alapból a 80-on figyel, de nem rootként 1024 alatti portot nem nyithat
   (a `runAsNonRoot` miatt): ezért kell a `--port=8080`. Az image nem ad meg felhasználót, ezért a
   `runAsUser: 65534` nélkül a kubelet el sem indítaná (`container has runAsNonRoot and image will run as root`).
3. **Átírás.** A Traefik alapból a teljes útvonalat továbbítja. Egy csak a `/`-en válaszoló app a `/api/sc`-re
   404-et adna. A levágást a `stripPrefix` Middleware végzi. Ez Traefik-specifikus (CRD + annotáció); az
   ingress-nginx-nél ugyanez a `rewrite-target` annotáció volt, ezért egy controller csere az átírásokat is
   érinti. A whoami minden útvonalon válaszol, ezért itt nem 404 jelzi a hibát, hanem az, hogy a kimenetben a
   `GET /api/sc` látszik a `GET /` helyett.
4. **A Middleware hivatkozása.** Az annotáció formája `<namespace>-<név>@kubernetescrd`: `demo-strip-api-sc@kubernetescrd`.
   Ha elírod, a Traefik az **egész routert** eldobja (404), és a logjában `middleware "…" does not exist` áll.
5. **Külön Ingress.** A `router.middlewares` annotáció az Ingress **minden** path-jára vonatkozik. Ha a `demo`
   Ingressbe tennéd a `/api/sc` path-t és az annotációt, a `/api/sa` és `/api/sb` kérések is átmennének a
   Middleware-en. Ez a `stripPrefix` ott éppen nem illeszkedik (nem változtat), de egy általánosabb
   (pl. `/api` levágás) vagy egy másfajta Middleware (auth, rate limit) már a Flask appokat is érintené.
   Útvonalanként eltérő viselkedés = külön Ingress.
6. **`pathType: Prefix` és a perjel.** A `stripPrefix` után a `/api/sc` üres útvonal lenne, ebből a Traefik `/`-t
   csinál; a `/api/sc/x`-ből `/x` lesz.

---

## 7. Buktatók és tanulságok

1. **Subnet tagek nélkül nincs NLB.** A Service `kubectl describe`-jában: `unable to resolve at least one subnet`.
   Internet-facing → `kubernetes.io/role/elb` a **publikus** subneteken; internal → `internal-elb` a privátokon.
2. **A 9443 nélkül a Helm release elbukik.** A control plane nem éri el az LB Controller webhookját, és a
   Traefik LoadBalancer Service létrehozása `failed calling webhook "mservice.elbv2.k8s.aws"` hibát ad.
3. **A lebontási sorrend.** Az NLB-t a controller hozza létre, a Terraform nem tud róla. Ha a cluster vagy a
   controller előbb tűnik el, az NLB ott marad (fizetős), és a `terraform destroy` `DependencyViolation`
   hibával elakad az NLB SG-n és a VPC-n. Ezért van a `depends_on` és a teardown külön lépése.
4. **Fix NLB név és csere.** Az `aws-load-balancer-name` annotáció miatt az NLB neve mindig `<cluster>-nlb`.
   Ha egy változás **új NLB-t igényel** (pl. a `scheme` internet-facing ↔ internal váltása, vagy maga a név
   változása), a controllernek új NLB-t kell létrehoznia. Egy régióban és accountban két NLB nem lehet azonos
   névvel: amíg a régi létezik, az új létrehozása `DuplicateLoadBalancerName` hibával elakad (a Service
   eseményei és a controller logja mutatja). Ilyenkor **előbb a régit kell törölni**: a Traefik release-t
   lebontani (`terraform destroy -target=module.traefik`), megvárni az NLB eltűnését, és csak utána alkalmazni
   a változást. Ez rövid kiesés, ezért ilyen változtatást karbantartási ablakban csinálj.
5. **Ugyanaz a backend szabály kétszer.** Saját NLB SG mellett a controller alapból nem kezeli a backend
   szabályokat, de ha a `manage-backend-security-group-rules` `"true"` lenne, a Terraform `node_from_nlb`
   szabályával ütközne (duplikált SG szabály). Egy szabálynak egy gazdája legyen.
6. **`ip` targetnél a kliens IP megőrzése alapból ki van kapcsolva.** Az annotáció nélkül a Traefik az NLB
   privát IP-jét látná, az access logban és az `X-Forwarded-For`-ban is.
7. **`trustedIPs` óvatosan.** Ha a Traefik `forwardedHeaders.trustedIPs`-be (vagy `insecure: true`) egy túl tág
   tartomány kerül, a kliens által küldött `X-Forwarded-For` is átmegy, és bárki bármilyen IP-t hazudhat.
   A mostani felállásban (megőrzött kliens IP) nincs rá szükség.
8. **A health check portja is szabály.** A `/ping` a 8080-on van: ha csak a 8000-re lenne szabály, a targetek
   `unhealthy`-k lennének. Ha minden target unhealthy, az NLB „fail open” módban mégis mindegyikre küld, így a
   curl működhet, miközben a health check hibás: félrevezető. Mindig a forgalmi **és** a health check portra kell
   szabály, mindkét SG-ben.
9. **A `strictPrefixMatching` nélkül** a Traefik a `/api/saxyz`-t is a service-a-hoz küldené (szöveges előtag).
   A Flask itt 404-et ad, de egy másik appnál ez meglepő útválasztást okozhat.
10. **A chart verzió és a policy együtt mozog.** Az LB Controller chart frissítésekor a hozzá illő
    `iam_policy.json`-t is le kell tölteni; egy régi policy mellett az új controller egyes műveletei
    `AccessDenied` hibát adnak (a controller logjában látszik).
11. **A Helm CRD-k megmaradnak.** A Traefik CRD-ket (`crds/` a chartban) a Helm telepíti, de uninstallkor nem
    törli. A cluster törlésével eltűnnek; egy megmaradó clusteren kézzel kell őket törölni.
12. **Cluster nélküli destroy.** Ha a cluster már nincs meg, a Helm provider nem tudja frissíteni a release-eket.
    `terraform state rm module.traefik.helm_release.this module.lb_controller.helm_release.this`, utána a
    destroy lefut. (Előtte győződj meg róla, hogy az NLB nem maradt ott.)
13. **Megosztott account.** A nevek (IAM szerepek, SG-k, ECR, NLB) a cluster nevéből képződnek: két projekt egy
    accountban csak eltérő cluster névvel fér meg (0.4). A teardown költségellenőrzése a régió **összes**
    load balancerét listázza, a sajátodat a névről ismered fel.
14. **Egy archivált projekt is lehet „a legelterjedtebb”.** Komponens választásnál a karbantartottság
    (kiadások, archivált-e, biztonsági javítások) legalább annyit számít, mint a népszerűség; és a forrást
    (parancsot) írd le, hogy később ellenőrizhető legyen.
