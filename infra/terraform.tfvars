# Do not put secret values in this file.
project_id = "kantacky"

region              = "asia-northeast1"
artifact_repository = "passkey"
image_name          = "server"

vpc_network_name = "kantacky"
vpc_subnet_name  = "kantacky"

cloud_sql_instance_name = "kantacky-psql"
database_name           = "passkey"
postgres_admin_username = "postgres"
mailgun_secret_name     = "mailgun-api-key"

cloud_run_service_name = "passkey-server"
migrate_job_name       = "passkey-migrate"
cleanup_job_name       = "passkey-cleanup"
scheduler_job_name     = "passkey-cleanup-hourly"

server_service_account_name     = "passkey-server"
migrator_service_account_name   = "passkey-migrator"
scheduler_service_account_name  = "passkey-scheduler"
web_proxy_service_account_name  = "passkey-web-proxy"
cloudbuild_service_account_name = "passkey-cloudbuild"

rp_id                = "passkey.kantacky.com"
origin               = "https://passkey.kantacky.com"
mailgun_domain       = "mail.passkey.kantacky.com"
mailgun_api_base_url = "https://api.mailgun.net"
mail_from            = "no-reply@mail.passkey.kantacky.com"
