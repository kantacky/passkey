resource "google_sql_database_instance" "postgres" {
  project          = var.project_id
  name             = var.cloud_sql_instance_name
  region           = var.region
  database_version = "POSTGRES_18"

  deletion_protection = true

  settings {
    tier                        = var.cloud_sql_tier
    edition                     = "ENTERPRISE"
    availability_type           = "ZONAL"
    deletion_protection_enabled = true

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
    }

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.main.id
      allocated_ip_range                            = google_compute_global_address.private_services.name
      enable_private_path_for_google_cloud_services = true
    }

    insights_config {
      query_insights_enabled = true
    }
  }

  depends_on = [
    google_project_service.apis["sqladmin.googleapis.com"],
    google_service_networking_connection.private_services,
  ]
}

resource "google_sql_database" "app" {
  project  = var.project_id
  name     = var.database_name
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_user" "server" {
  project  = var.project_id
  name     = trimsuffix(google_service_account.server.email, ".gserviceaccount.com")
  instance = google_sql_database_instance.postgres.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  database_roles = [
    "pg_read_all_data",
    "pg_write_all_data",
  ]

  deletion_policy = "ABANDON"
}

resource "google_sql_user" "migrator" {
  project  = var.project_id
  name     = trimsuffix(google_service_account.migrator.email, ".gserviceaccount.com")
  instance = google_sql_database_instance.postgres.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  # PostgreSQL has no global DDL-only predefined role. Limit this broad role
  # to the dedicated migration account.
  database_roles = ["cloudsqlsuperuser"]

  deletion_policy = "ABANDON"
}
