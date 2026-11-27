data "google_compute_network" "main" {
  project = var.project_id
  name    = var.vpc_network_name
}

data "google_compute_subnetwork" "main" {
  project = var.project_id
  name    = var.vpc_subnet_name
  region  = var.region
}
