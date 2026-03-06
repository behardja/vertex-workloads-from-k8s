variable "project_id" {
  description = "Google Cloud project ID"
  type        = string
}

variable "region" {
  description = "Google Cloud region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Google Cloud zone for the GKE cluster"
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "vertex-tpu-demo"
}

variable "network" {
  description = "VPC network for the GKE cluster"
  type        = string
  default     = "default"
}

variable "repo_name" {
  description = "Artifact Registry repository name for training images"
  type        = string
  default     = "tpu-training-repository"
}
