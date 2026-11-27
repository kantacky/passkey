terraform {
  backend "gcs" {
    # GCS backend cannot use variables. Replace this placeholder with the
    # globally unique bucket created in docs/deploy.md before terraform init.
    bucket = "__GCP_PROJECT_ID__-passkey-terraform-state"
    prefix = "passkey"
  }
}
