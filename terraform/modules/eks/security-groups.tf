# FONTOS: a szabályok külön erőforrások (aws_vpc_security_group_ingress_rule / egress_rule),
# nem inline ingress/egress blokkok. Inline blokkoknál a Terraform a security group ÖSSZES
# szabályát kezelné, és a következő apply törölné azokat, amelyeket más (nem a Terraform)
# vesz fel a SG-be.

locals {
  # A control plane által a node-okon/podokon elért portok (név => port)
  cluster_to_node_ports = {
    https   = 443   # pl. a control plane webhookjai a 443-on figyelő podok felé
    kubelet = 10250 # kubectl logs/exec, a kubelet API
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

# Security group a node-oknak (a launch template rakja rájuk).
resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node"
  description = "EKS managed node group"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.cluster_name}-node"
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
# vonatkozik rájuk is (pl. podok közti forgalom különböző node-okon, CoreDNS lekérdezések).
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

# A node-ok kifelé bárhová kapcsolódhatnak (ECR, EKS API, S3 – a NAT gatewayen át).
resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All outbound"
}
