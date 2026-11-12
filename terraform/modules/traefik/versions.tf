# Minimális provider verzió; a pontos rögzítés a rootban van. Provider blokk itt NINCS
# (a Helm provider a rootban van konfigurálva, a modul azt örökli).
terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0"
    }
  }
}
