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

# EKS cluster: IAM szerepek, security groupok, cluster, addonok,
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

  # Aki a Terraformot futtatja (IAM user), cluster admin lesz
  cluster_admin_principal_arns = [data.aws_caller_identity.current.arn]
}
