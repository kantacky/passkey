resource "google_artifact_registry_repository" "container_images" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_repository
  format        = "DOCKER"
  description   = "Passkey server container images"

  depends_on = [google_project_service.apis["artifactregistry.googleapis.com"]]
}
