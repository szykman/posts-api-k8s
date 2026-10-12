terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state is mandatory for a team (locking, history, no state on a laptop). Create the bucket once,
  # with versioning on, then uncomment:
  #
  # backend "gcs" {
  #   bucket = "<project>-tfstate"
  #   prefix = "posts-api/gke"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
