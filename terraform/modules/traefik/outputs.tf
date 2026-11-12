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
