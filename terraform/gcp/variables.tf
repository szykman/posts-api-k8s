variable "project_id" {
  description = "GCP project that will hold everything. Use a dedicated project so that deleting it cleans up."
  type        = string
}

variable "region" {
  description = "Region of the cluster. A regional cluster spreads nodes over the zones of the region."
  type        = string
  default     = "southamerica-east1"
}

variable "name" {
  description = "Prefix for the resource names."
  type        = string
  default     = "posts"
}

variable "deletion_protection" {
  description = "Protect the cluster and the database from terraform destroy. Turn off only for a throw-away trial."
  type        = bool
  default     = true
}

variable "create_database" {
  description = "Create a Cloud SQL (MySQL) instance with a standby in another zone. It is the expensive part: leave false to trial the cluster."
  type        = bool
  default     = false
}

variable "database_tier" {
  description = "Machine tier of the Cloud SQL instance."
  type        = string
  default     = "db-custom-1-3840"
}
