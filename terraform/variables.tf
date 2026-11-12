variable "region" {
  description = "AWS régió"
  type        = string
}

variable "cluster_name" {
  description = "Az EKS cluster neve (a legtöbb erőforrás neve is ebből képződik)"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes verzió (ellenőrizd, hogy standard támogatásban van-e: aws eks describe-cluster-versions)"
  type        = string
}

variable "vpc_cidr" {
  description = "A VPC címtartománya; a subnets CIDR-jeinek ebbe kell esniük"
  type        = string
}

variable "subnets" {
  description = "Subnetek AZ-nként: a kulcs az AZ neve, az érték a privát és a publikus subnet CIDR-je"
  type = map(object({
    private_cidr = string
    public_cidr  = string
  }))

  validation {
    condition     = length(var.subnets) >= 2
    error_message = "Az EKS-hez legalább 2 AZ kell."
  }

  validation {
    condition = alltrue(flatten([
      for s in values(var.subnets) : [can(cidrhost(s.private_cidr, 0)), can(cidrhost(s.public_cidr, 0))]
    ]))
    error_message = "Minden private_cidr és public_cidr érvényes CIDR legyen (pl. 10.0.0.0/20)."
  }
}

variable "node_instance_types" {
  description = "A managed node group EC2 instance típusai"
  type        = list(string)
}

variable "node_ami_type" {
  description = "A node-ok AMI típusa; illeszkednie kell a node_instance_types architektúrájához (t3 = x86)"
  type        = string
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Mely IP-tartományokból érhető el a publikus EKS API endpoint (gyakorláshoz mindenhonnan; élesben szűkítsd a saját IP-dre)"
  type        = list(string)
}

variable "node_desired_size" {
  description = "A node group kívánt node száma"
  type        = number
}

variable "node_min_size" {
  description = "A node group minimális node száma"
  type        = number
}

variable "node_max_size" {
  description = "A node group maximális node száma"
  type        = number
}

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

variable "ecr_image_tag_mutability" {
  description = "MUTABLE: ugyanaz a tag felülírható (gyakorláshoz); IMMUTABLE: egy tag csak egyszer tölthető fel (élesben ajánlott)"
  type        = string
}

variable "ecr_force_delete" {
  description = "true: a repó akkor is törölhető, ha van benne image (gyakorláshoz, hogy a destroy lefusson); élesben false"
  type        = bool
}