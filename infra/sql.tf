data "google_sql_database_instance" "postgres" {
  project = var.project_id
  name    = var.cloud_sql_instance_name
}

resource "google_sql_database" "app" {
  project  = var.project_id
  name     = var.database_name
  instance = data.google_sql_database_instance.postgres.name
}

resource "google_sql_user" "server" {
  project  = var.project_id
  name     = trimsuffix(google_service_account.server.email, ".gserviceaccount.com")
  instance = data.google_sql_database_instance.postgres.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  deletion_policy = "ABANDON"
}

resource "google_sql_user" "migrator" {
  project  = var.project_id
  name     = trimsuffix(google_service_account.migrator.email, ".gserviceaccount.com")
  instance = data.google_sql_database_instance.postgres.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"

  deletion_policy = "ABANDON"
}

resource "postgresql_grant" "server_database_connect" {
  database    = google_sql_database.app.name
  role        = google_sql_user.server.name
  object_type = "database"
  privileges  = ["CONNECT"]

  depends_on = [
    google_sql_database.app,
    google_sql_user.server,
  ]
}

resource "postgresql_grant" "server_schema_usage" {
  database    = google_sql_database.app.name
  role        = google_sql_user.server.name
  schema      = "public"
  object_type = "schema"
  privileges  = ["USAGE"]

  depends_on = [
    google_sql_database.app,
    google_sql_user.server,
  ]
}

resource "postgresql_grant" "server_table_dml" {
  database    = google_sql_database.app.name
  role        = google_sql_user.server.name
  schema      = "public"
  object_type = "table"
  privileges  = ["SELECT", "INSERT", "UPDATE", "DELETE"]

  depends_on = [
    google_sql_database.app,
    google_sql_user.server,
  ]
}

resource "postgresql_grant" "server_sequence_dml" {
  database    = google_sql_database.app.name
  role        = google_sql_user.server.name
  schema      = "public"
  object_type = "sequence"
  privileges  = ["USAGE", "SELECT"]

  depends_on = [
    google_sql_database.app,
    google_sql_user.server,
  ]
}

resource "postgresql_grant" "migrator_database_connect" {
  database    = google_sql_database.app.name
  role        = google_sql_user.migrator.name
  object_type = "database"
  privileges  = ["CONNECT"]

  depends_on = [
    google_sql_database.app,
    google_sql_user.migrator,
  ]
}

resource "postgresql_grant" "migrator_schema_ddl" {
  database    = google_sql_database.app.name
  role        = google_sql_user.migrator.name
  schema      = "public"
  object_type = "schema"
  privileges  = ["CREATE", "USAGE"]

  depends_on = [
    google_sql_database.app,
    google_sql_user.migrator,
  ]
}

resource "postgresql_default_privileges" "server_table_dml" {
  database    = google_sql_database.app.name
  role        = google_sql_user.server.name
  owner       = google_sql_user.migrator.name
  schema      = "public"
  object_type = "table"
  privileges  = ["SELECT", "INSERT", "UPDATE", "DELETE"]

  depends_on = [
    google_sql_database.app,
    google_sql_user.server,
    google_sql_user.migrator,
  ]
}

resource "postgresql_default_privileges" "server_sequence_dml" {
  database    = google_sql_database.app.name
  role        = google_sql_user.server.name
  owner       = google_sql_user.migrator.name
  schema      = "public"
  object_type = "sequence"
  privileges  = ["USAGE", "SELECT"]

  depends_on = [
    google_sql_database.app,
    google_sql_user.server,
    google_sql_user.migrator,
  ]
}
