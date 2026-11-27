resource "google_compute_network" "main" {
  project                 = var.project_id
  name                    = var.vpc_network_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.apis["compute.googleapis.com"]]
}

resource "google_compute_subnetwork" "main" {
  project       = var.project_id
  name          = var.vpc_subnet_name
  region        = var.region
  network       = google_compute_network.main.id
  ip_cidr_range = var.vpc_subnet_range

  private_ip_google_access = true
}

resource "google_compute_global_address" "private_services" {
  project       = var.project_id
  name          = var.private_services_range_name
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = var.private_services_address
  prefix_length = var.private_services_prefix_length
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]

  depends_on = [google_project_service.apis["servicenetworking.googleapis.com"]]
}
