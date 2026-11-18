resource "google_project_service" "enabled" {
  for_each           = toset(var.enabled_services)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_pubsub_topic" "topic" {
  project    = var.project_id
  name       = var.topic_name
  depends_on = [google_project_service.enabled]
}

resource "google_service_account" "ci" {
  project      = var.project_id
  account_id   = var.service_account_id
  display_name = var.service_account_display_name
  depends_on   = [google_project_service.enabled]
}

resource "google_project_iam_member" "ci_roles" {
  for_each = toset(var.service_account_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.ci.email}"
}
