locals {
  # A Traefik Service-ének annotációi. Ezeket NEM a Traefik olvassa, hanem az AWS Load
  # Balancer Controller: ezekből tudja, milyen NLB-t hozzon létre a LoadBalancer Service-hez.
  service_annotations = {
    # Az AWS Load Balancer Controller kezelje (nem a régi, beépített cloud provider), és NLB legyen
    "service.beta.kubernetes.io/aws-load-balancer-type" = "external"
    # Publikus legyen (alapból internal lenne!), a kubernetes.io/role/elb taggelt subnetekben
    "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
    # ip: az NLB közvetlenül a Traefik podok IP-jére küld (nincs NodePort, nincs kube-proxy ugrás)
    "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
    # Fix név: a teardown.sh név szerint várja meg a törlését. Ára: a csere (pl. scheme
    # változás) csak a régi NLB törlése után mehet, mert két NLB nem lehet azonos névvel.
    "service.beta.kubernetes.io/aws-load-balancer-name" = var.load_balancer_name
    # A Terraformban létrehozott NLB security group, közvetlenül (nem kell a manifestet patchelni)
    "service.beta.kubernetes.io/aws-load-balancer-security-groups" = var.nlb_security_group_id
    # A node SG szabályait a Terraform kezeli (node_from_nlb); ha a controller is felvenné,
    # az AWS duplikált szabályként utasítaná el
    "service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules" = "false"
    # ip targetnél a kliens IP megőrzése alapból KI van kapcsolva; így a Traefik a valódi
    # kliens IP-t látja forrásként, és azt írja az X-Forwarded-For fejlécbe
    "service.beta.kubernetes.io/aws-load-balancer-target-group-attributes" = "preserve_client_ip.enabled=true"
    # HTTP health check a Traefik /ping végpontjára (a "traefik" entrypoint portján): a TCP
    # check akkor is zöld lenne, ha a port nyitva van, de a Traefik még nem kész
    "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol" = "http"
    "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"     = tostring(var.ports["ping"])
    "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"     = "/ping"
  }

  # A chart értékei (helm show values traefik/traefik --version <verzió>). A yamlencode miatt
  # a pontokat tartalmazó annotáció kulcsokat nem kell escape-elni (a set listával ellentétben).
  helm_values = {
    deployment = {
      replicas = var.replicas
    }

    # Node csere / leürítés közben is maradjon legalább egy futó Traefik pod
    podDisruptionBudget = {
      enabled        = true
      maxUnavailable = 1
    }

    # Az IngressClass: az Ingress objektumok az ingressClassName mezővel erre hivatkoznak.
    # Nem alapértelmezett, így minden Ingressnek ki kell mondania, melyik controllerhez tartozik.
    ingressClass = {
      enabled        = true
      isDefaultClass = false
      name           = var.ingress_class_name
    }

    providers = {
      kubernetesIngress = {
        # A Kubernetes spec szerinti Prefix illesztés útvonal elemenként: /api/sa illeszkedik a
        # /api/sa és /api/sa/x útvonalra, de a /api/saxyz-re nem (alapból a Traefik szövegesen illesztene)
        strictPrefixMatching = true
      }
    }

    # Kérésenkénti napló (kliens IP, útvonal, státusz, melyik backend): a teszteléshez és a hibakereséshez
    accessLog = {
      enabled = true
    }

    ports = {
      # A "traefik" entrypoint: itt van a /ping (readiness, liveness és az NLB health check).
      # Nincs kitéve a Service-en (expose.default = false a chart alapértéke).
      traefik = {
        port = var.ports["ping"]
      }
      # A "web" entrypoint: ide jön az NLB forgalma; a Service 80-as portja erre mutat.
      # A forwardedHeaders.trustedIPs üres (alapérték): a klienstől jövő X-Forwarded-* fejléceket
      # a Traefik nem fogadja el, hanem a valódi forrás IP-vel állítja be.
      web = {
        port = var.ports["web"]
      }
      # HTTPS-t most nem szolgálunk ki (nincs TLS), ezért nem kerül a Service-re
      websecure = {
        expose = {
          default = false
        }
      }
    }

    resources = {
      requests = {
        cpu    = "100m"
        memory = "128Mi"
      }
      limits = {
        memory = "256Mi"
      }
    }

    service = {
      annotations = local.service_annotations
      spec = {
        # ip targetnél az NLB nem használ NodePortot, ezért ne is foglaljon a Service
        allocateLoadBalancerNodePorts = false
      }
    }
  }
}

# A Traefik Ingress controller telepítése Helm charttal. A chart létrehozza a Deploymentet,
# a LoadBalancer Service-t (ebből csinál NLB-t az AWS Load Balancer Controller), az
# IngressClass-t, a PodDisruptionBudgetet, az RBAC-ot és a Traefik CRD-ket (pl. Middleware).
# Lebontáskor a wait (alapból true) miatt a Helm megvárja, amíg a Service ténylegesen törlődik,
# vagyis amíg a controller a finalizere előtt az NLB-t is törli.
resource "helm_release" "this" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  values = [yamlencode(local.helm_values)]
}
