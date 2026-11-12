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
