variable "project_id" {
  type        = string
  description = "The GCP project ID to manage."
}

variable "region" {
  type        = string
  description = "Default region for regional resources."
}

variable "topic_name" {
  type        = string
  description = "Pub/Sub topic name for action dispatch events."
}

variable "service_account_id" {
  type        = string
  description = "The service account ID (without domain)."
}

variable "service_account_display_name" {
  type        = string
  description = "Display name to assign to the CI service account."
}

variable "service_account_roles" {
  type        = list(string)
  description = "Project roles to grant to the CI service account."
  default = [
    "roles/cloudfunctions.developer",
    "roles/iam.serviceAccountUser",
    "roles/pubsub.admin",
    "roles/secretmanager.secretAccessor",
  ]
}

variable "enabled_services" {
  type        = list(string)
  description = "Google APIs that must be enabled on the project."
  default = [
    "cloudfunctions.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
  ]
}
