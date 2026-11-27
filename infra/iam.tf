locals {
  database_runtime_service_accounts = {
    server   = google_service_account.server.email
    migrator = google_service_account.migrator.email
  }
}

resource "google_project_iam_member" "database_runtime_cloudsql_client" {
  for_each = local.database_runtime_service_accounts

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${each.value}"
}

resource "google_project_iam_member" "database_runtime_cloudsql_instance_user" {
  for_each = local.database_runtime_service_accounts

  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${each.value}"
}

resource "google_artifact_registry_repository_iam_member" "database_runtime_image_reader" {
  for_each = local.database_runtime_service_accounts

  project    = var.project_id
  location   = google_artifact_registry_repository.container_images.location
  repository = google_artifact_registry_repository.container_images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${each.value}"
}

resource "google_project_iam_member" "cloudbuild_project_roles" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/storage.objectViewer",
    "roles/run.admin",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.cloudbuild.email}"
}

resource "google_artifact_registry_repository_iam_member" "cloudbuild_image_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.container_images.location
  repository = google_artifact_registry_repository.container_images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cloudbuild.email}"
}

resource "google_service_account_iam_member" "cloudbuild_can_use_server" {
  service_account_id = google_service_account.server.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.cloudbuild.email}"
}

resource "google_service_account_iam_member" "cloudbuild_can_use_migrator" {
  service_account_id = google_service_account.migrator.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.cloudbuild.email}"
}

resource "google_cloud_run_v2_service_iam_member" "web_proxy_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_service.server.location
  name     = google_cloud_run_v2_service.server.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.web_proxy.email}"
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_cleanup_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_job.cleanup.location
  name     = google_cloud_run_v2_job.cleanup.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}
