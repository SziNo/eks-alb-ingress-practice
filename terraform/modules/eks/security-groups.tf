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
