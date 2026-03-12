terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Configure kubernetes and helm providers after cluster creation
provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
}

data "google_client_config" "default" {}

# ---------- APIs ----------

resource "google_project_service" "apis" {
  for_each = toset([
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "container.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ---------- GKE Cluster ----------

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone
  project  = var.project_id
  network  = var.network

  initial_node_count = 1

  node_config {
    machine_type = "n1-standard-16"
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  cluster_autoscaling {
    enabled = true
    resource_limits {
      resource_type = "cpu"
      minimum       = 1
      maximum       = 64
    }
    resource_limits {
      resource_type = "memory"
      minimum       = 1
      maximum       = 256
    }
  }

  vertical_pod_autoscaling {
    enabled = true
  }

  deletion_protection = false

  depends_on = [google_project_service.apis]
}

# ---------- Artifact Registry ----------

resource "google_artifact_registry_repository" "training" {
  location      = var.region
  repository_id = var.repo_name
  format        = "DOCKER"
  description   = "Vertex TPU training container images"
  depends_on    = [google_project_service.apis]
}

# ---------- GCS Bucket ----------

resource "google_storage_bucket" "pipeline_root" {
  name                        = "${var.project_id}-tpu-pipeline-root"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
}

# ---------- Workload Identity ----------

resource "google_service_account" "jupyterhub" {
  account_id   = "jupyterhub-gke-sa"
  display_name = "JupyterHub GKE Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "roles" {
  for_each = toset([
    "roles/aiplatform.user",
    "roles/artifactregistry.admin",
    "roles/storage.objectAdmin",
    "roles/cloudbuild.builds.editor",
    "roles/cloudbuild.builds.builder",
    "roles/logging.viewer",
    "roles/serviceusage.serviceUsageAdmin",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.jupyterhub.email}"
}

resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.jupyterhub.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[jupyterhub/jupyterhub-sa]"
}

# Allow JupyterHub GSA to act as the default compute SA when submitting Vertex AI jobs
data "google_compute_default_service_account" "default" {
  project = var.project_id
}

resource "google_service_account_iam_member" "act_as_compute_sa" {
  service_account_id = data.google_compute_default_service_account.default.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.jupyterhub.email}"
}

# ---------- Kubernetes Namespace & Service Account ----------

resource "kubernetes_namespace_v1" "jupyterhub" {
  metadata {
    name = "jupyterhub"
  }
  depends_on = [google_container_cluster.primary]
}

resource "kubernetes_service_account_v1" "jupyterhub" {
  metadata {
    name      = "jupyterhub-sa"
    namespace = "jupyterhub"
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.jupyterhub.email
    }
  }
  depends_on = [kubernetes_namespace_v1.jupyterhub]
}

# ---------- Notebook ConfigMap ----------

resource "kubernetes_config_map_v1" "notebook" {
  metadata {
    name      = "submit-tpu-job-notebook"
    namespace = "jupyterhub"
  }
  data = {
    "custom_container_tpu_job.ipynb"  = file("${path.module}/../notebooks/custom_container_tpu_job.ipynb")
    "prebuilt_container_tpu_job.ipynb" = file("${path.module}/../notebooks/prebuilt_container_tpu_job.ipynb")
  }
  depends_on = [kubernetes_namespace_v1.jupyterhub]
}

# ---------- JupyterHub (Helm) ----------

resource "helm_release" "jupyterhub" {
  name       = "jupyterhub"
  repository = "https://hub.jupyter.org/helm-chart/"
  chart      = "jupyterhub"
  namespace  = "jupyterhub"
  timeout    = 600

  values = [file("${path.module}/jupyterhub-values.yaml")]

  depends_on = [
    google_container_cluster.primary,
    kubernetes_service_account_v1.jupyterhub,
  ]
}
