# A scripts/ és a README ezekre a nevekre hivatkozik, ezért a nevek nem változtak.

output "region" {
  description = "AWS régió (a scriptek ebből tudják, hol dolgozzanak)"
  value       = var.region
}

output "cluster_name" {
  description = "Az EKS cluster neve"
  value       = module.eks.cluster_name
}

output "ecr_repository_urls" {
  description = "Szolgáltatás neve => ECR repó címe"
  value       = module.ecr.repository_urls
}

output "kubeconfig_command" {
  description = "Ezzel a paranccsal állítható be a kubectl a clusterhez"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

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
