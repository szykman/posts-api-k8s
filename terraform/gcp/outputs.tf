output "cluster_name" {
  value = google_container_cluster.gke.name
}

output "get_credentials" {
  description = "Command that points kubectl at the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.gke.name} --region ${var.region} --project ${var.project_id}"
}

output "image_repository" {
  description = "Where to push the image if you use the private registry."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "database_private_ip" {
  description = "Value for database.host in the Helm chart (empty when create_database is false)."
  value       = var.create_database ? google_sql_database_instance.db[0].private_ip_address : ""
}
