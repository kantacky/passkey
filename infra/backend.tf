terraform {
  backend "gcs" {
    # GCS backend cannot use variables. Created with gcloud as described in docs/deploy.md.
    bucket = "kantacky-passkey-terraform-state"
    prefix = "passkey"
  }
}
