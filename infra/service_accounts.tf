resource "google_service_account" "cloudbuild" {
  project      = var.project_id
  account_id   = var.cloudbuild_service_account_name
  display_name = "passkey: Cloud Build deployment"
}

resource "google_service_account" "server" {
  project      = var.project_id
  account_id   = var.server_service_account_name
  display_name = "passkey: Cloud Run service"
}

resource "google_service_account" "migrator" {
  project      = var.project_id
  account_id   = var.migrator_service_account_name
  display_name = "passkey: database migrator"
}

resource "google_service_account" "scheduler" {
  project      = var.project_id
  account_id   = var.scheduler_service_account_name
  display_name = "passkey: cleanup scheduler"
}

resource "google_service_account" "web_proxy" {
  project      = var.project_id
  account_id   = var.web_proxy_service_account_name
  display_name = "passkey: Cloudflare Worker proxy"
}
