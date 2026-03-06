output "jupyterhub_url" {
  description = "JupyterHub external URL"
  value       = "http://${data.kubernetes_service_v1.jupyterhub_proxy.status[0].load_balancer[0].ingress[0].ip}"
}

output "cluster_connection_command" {
  description = "Command to connect to the GKE cluster"
  value       = "gcloud container clusters get-credentials ${var.cluster_name} --zone ${var.zone} --project ${var.project_id}"
}

output "gsa_email" {
  description = "Google Service Account email used by JupyterHub pods"
  value       = google_service_account.jupyterhub.email
}

data "kubernetes_service_v1" "jupyterhub_proxy" {
  metadata {
    name      = "proxy-public"
    namespace = "jupyterhub"
  }
  depends_on = [helm_release.jupyterhub]
}
