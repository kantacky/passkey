variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  description = "Primary GCP region."
}

variable "artifact_repository" {
  type        = string
  description = "Artifact Registry repository ID."
}

variable "image_name" {
  type        = string
  description = "Server image name in Artifact Registry."
}

variable "vpc_network_name" {
  type        = string
  description = "VPC network name."
}

variable "vpc_subnet_name" {
  type        = string
  description = "VPC subnetwork name."
}

variable "cloud_sql_instance_name" {
  type        = string
  description = "Cloud SQL instance name."
}

variable "database_name" {
  type        = string
  description = "Application database name."
}

variable "postgres_admin_username" {
  type        = string
  description = "Built-in PostgreSQL user Terraform uses for privilege management. PGPASSWORD supplies its password."
}

variable "mailgun_secret_name" {
  type        = string
  description = "Secret Manager secret ID for the Mailgun API key. Terraform creates only the secret container."
}

variable "cloud_run_service_name" {
  type        = string
  description = "Cloud Run service name."
}

variable "migrate_job_name" {
  type        = string
  description = "Cloud Run migrate job name."
}

variable "cleanup_job_name" {
  type        = string
  description = "Cloud Run cleanup job name."
}

variable "scheduler_job_name" {
  type        = string
  description = "Cloud Scheduler job name."
}

variable "server_service_account_name" {
  type        = string
  description = "Service account ID for the Cloud Run service and cleanup job."
}

variable "migrator_service_account_name" {
  type        = string
  description = "Service account ID for the migrate job."
}

variable "scheduler_service_account_name" {
  type        = string
  description = "Service account ID used by Cloud Scheduler."
}

variable "web_proxy_service_account_name" {
  type        = string
  description = "Service account ID used by the Cloudflare Worker."
}

variable "cloudbuild_service_account_name" {
  type        = string
  description = "Service account ID used to run normal Cloud Build deployments."
}

variable "rp_id" {
  type        = string
  description = "WebAuthn relying party ID."
}

variable "origin" {
  type        = string
  description = "Allowed WebAuthn origin."
}

variable "mailgun_domain" {
  type        = string
  description = "Mailgun sending domain."
}

variable "mailgun_api_base_url" {
  type        = string
  description = "Mailgun API base URL."
}

variable "mail_from" {
  type        = string
  description = "Mail From header address."
}
