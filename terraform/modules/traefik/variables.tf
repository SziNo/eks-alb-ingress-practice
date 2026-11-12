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
