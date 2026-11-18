output "service_account_email" {
  description = "Email address for the CI service account."
  value       = google_service_account.ci.email
}

output "pubsub_topic_name" {
  description = "Name of the Pub/Sub topic used for dispatch."
  value       = google_pubsub_topic.topic.name
}
