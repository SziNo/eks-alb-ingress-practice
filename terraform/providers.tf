# Provider blokkok CSAK itt, a root modulban vannak; a saját modulok ezeket öröklik.

# AWS provider: a régiót változóból kapja. A default_tags minden AWS erőforrásra
# rákerül, így a konzolban és a számlán is látszik, mi tartozik a projekthez.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.cluster_name
      ManagedBy = "terraform"
    }
  }
}
