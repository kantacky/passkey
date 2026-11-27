output "cloud_run_service_url" {
  description = "Cloud Run service URL. Use this as CLOUD_RUN_URL in web/cloudflare.config.ts."
  value       = google_cloud_run_v2_service.server.uri
}

output "cloud_sql_connection_name" {
  description = "Cloud SQL connection name."
  value       = google_sql_database_instance.postgres.connection_name
}

output "server_image_repository" {
  description = "Artifact Registry path prefix for server images."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repository}/${var.image_name}"
}

output "web_proxy_service_account_email" {
  description = "Service account email used by the Cloudflare Worker."
  value       = google_service_account.web_proxy.email
}
