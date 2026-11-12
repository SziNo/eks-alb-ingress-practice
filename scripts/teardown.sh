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
