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
