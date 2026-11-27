locals {
  placeholder_service_image = "us-docker.pkg.dev/cloudrun/container/hello"
  placeholder_job_image     = "us-docker.pkg.dev/cloudrun/container/job"
}

resource "google_cloud_run_v2_service" "server" {
  project             = var.project_id
  name                = var.cloud_run_service_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = true

  labels = {
    app = "passkey-server"
  }

  template {
    service_account       = google_service_account.server.email
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = var.vpc_network_name
        subnetwork = var.vpc_subnet_name
      }
    }

    containers {
      image = local.placeholder_service_image
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  # The first apply creates the resource with a placeholder. server/deploy/cloudbuild.yaml
  # owns image and revision-template updates during normal application deploys.
  lifecycle {
    ignore_changes = [
      template,
      traffic,
    ]
  }

  depends_on = [
    google_project_service.apis["run.googleapis.com"],
    google_compute_subnetwork.main,
  ]
}

resource "google_cloud_run_v2_job" "migrate" {
  project             = var.project_id
  name                = var.migrate_job_name
  location            = var.region
  deletion_protection = true

  labels = {
    app = "passkey-server"
  }

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = google_service_account.migrator.email
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout               = "600s"
      max_retries           = 1

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          network    = var.vpc_network_name
          subnetwork = var.vpc_subnet_name
        }
      }

      containers {
        image = local.placeholder_job_image
      }
    }
  }

  lifecycle {
    ignore_changes = [template]
  }

  depends_on = [
    google_project_service.apis["run.googleapis.com"],
    google_compute_subnetwork.main,
  ]
}

resource "google_cloud_run_v2_job" "cleanup" {
  project             = var.project_id
  name                = var.cleanup_job_name
  location            = var.region
  deletion_protection = true

  labels = {
    app = "passkey-server"
  }

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = google_service_account.server.email
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout               = "600s"
      max_retries           = 1

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          network    = var.vpc_network_name
          subnetwork = var.vpc_subnet_name
        }
      }

      containers {
        image = local.placeholder_job_image
      }
    }
  }

  lifecycle {
    ignore_changes = [template]
  }

  depends_on = [
    google_project_service.apis["run.googleapis.com"],
    google_compute_subnetwork.main,
  ]
}

resource "google_cloud_scheduler_job" "cleanup_hourly" {
  project     = var.project_id
  name        = var.scheduler_job_name
  region      = var.region
  description = "Run the passkey cleanup Cloud Run job hourly"
  schedule    = "0 * * * *"
  time_zone   = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${var.cleanup_job_name}:run"

    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.apis["cloudscheduler.googleapis.com"],
    google_cloud_run_v2_job.cleanup,
  ]
}
