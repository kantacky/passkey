terraform {
  required_version = "1.17.2"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.12.0"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "1.27.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "postgresql" {
  scheme    = "gcppostgres"
  host      = data.google_sql_database_instance.postgres.connection_name
  username  = var.postgres_admin_username
  superuser = false
}
