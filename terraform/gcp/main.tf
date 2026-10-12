# SKETCH. Written to be read and defended, validated with `terraform validate`, but never applied.
# Everything here costs money once applied (see docs/GKE.md for a cheap way to try it).

locals {
  services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
  ]
}

resource "google_project_service" "enabled" {
  for_each           = toset(local.services)
  service            = each.value
  disable_on_destroy = false
}

# --- Network -----------------------------------------------------------------------------------------------
# A dedicated VPC. The pod and service ranges are secondary ranges of the subnet (VPC-native cluster), so pods
# get routable IPs and can reach the database over private IP.
resource "google_compute_network" "vpc" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.enabled]
}

resource "google_compute_subnetwork" "gke" {
  name                     = "${var.name}-gke"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.10.0.0/20"
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }
}

# --- Cluster -----------------------------------------------------------------------------------------------
# Autopilot: Google manages the nodes, and billing is per pod request, which suits a small workload. A regional
# cluster runs across the zones of the region, which is what topologySpreadConstraints on
# topology.kubernetes.io/zone needs. Standard mode (node pools, taints, machine types) would be chosen for
# special hardware or tighter cost control.
resource "google_container_cluster" "gke" {
  name     = "${var.name}-gke"
  location = var.region

  enable_autopilot    = true
  deletion_protection = var.deletion_protection

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.gke.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  release_channel {
    channel = "REGULAR"
  }

  depends_on = [google_project_service.enabled]
}

# --- Images ------------------------------------------------------------------------------------------------
# The private registry. Nodes in the same project pull from it with the node service account, so no
# imagePullSecret is needed (the account needs roles/artifactregistry.reader, which the default compute
# service account does not always have: grant it explicitly in a real setup).
resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "${var.name}-images"
  format        = "DOCKER"
  description   = "Container images for posts-api"

  depends_on = [google_project_service.enabled]
}

# --- Database (optional) -----------------------------------------------------------------------------------
# Cloud SQL for MySQL with high availability: a standby in another zone of the region, synchronous
# replication of committed data, automatic failover. Private IP only: reachable from the VPC, not the internet.
# See docs/decisions/0004-database-availability.md for why this is the production answer.
resource "google_compute_global_address" "sql_range" {
  count         = var.create_database ? 1 : 0
  name          = "${var.name}-sql-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "sql" {
  count                   = var.create_database ? 1 : 0
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql_range[0].name]
}

resource "google_sql_database_instance" "db" {
  count               = var.create_database ? 1 : 0
  name                = "${var.name}-db"
  region              = var.region
  database_version    = "MYSQL_8_0"
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.database_tier
    availability_type = "REGIONAL"
    disk_size         = 10
    disk_autoresize   = true

    backup_configuration {
      enabled            = true
      binary_log_enabled = true # point-in-time recovery
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }
  }

  depends_on = [google_service_networking_connection.sql]
}

resource "google_sql_database" "posts" {
  count    = var.create_database ? 1 : 0
  name     = "posts"
  instance = google_sql_database_instance.db[0].name
}

# The password is generated here and ends up in the Terraform state, so the state must be protected (remote
# bucket, restricted access). The better production path is Secret Manager plus External Secrets, so that the
# value never passes through Terraform at all.
resource "random_password" "db" {
  count   = var.create_database ? 1 : 0
  length  = 32
  special = false
}

resource "google_sql_user" "app" {
  count    = var.create_database ? 1 : 0
  name     = "posts"
  instance = google_sql_database_instance.db[0].name
  password = random_password.db[0].result
}
