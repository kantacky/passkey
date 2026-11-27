resource "google_secret_manager_secret" "mailgun_api_key" {
  project   = var.project_id
  secret_id = var.mailgun_secret_name

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_iam_member" "server_mailgun_api_key_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.mailgun_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.server.email}"
}
