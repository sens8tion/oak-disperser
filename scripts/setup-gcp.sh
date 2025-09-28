#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/setup-gcp.sh --project <project-id> [options]

Options:
  --region <region>                Deployment region (default: us-central1)
  --service-account-id <id>        Service account ID (default: oak-disperser-ci)
  --service-account-name <name>    Service account display name (default: Oak Disperser CI)
  --topic <topic>                  Pub/Sub topic name (default: action-dispersal)
  --key-output <path>              Where to write the generated key JSON (default: ./gcp-service-account-key.json)
  --skip-key                       Do not create a service account key
  --dry-run                        Print commands without executing them
  -h, --help                       Show this message
USAGE
}

PROJECT_ID=""
REGION="us-central1"
SERVICE_ACCOUNT_ID="oak-disperser-ci"
SERVICE_ACCOUNT_NAME="Oak Disperser CI"
PUBSUB_TOPIC="action-dispersal"
KEY_OUTPUT_PATH=""
SKIP_KEY="false"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_ID="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --service-account-id)
      SERVICE_ACCOUNT_ID="$2"
      shift 2
      ;;
    --service-account-name)
      SERVICE_ACCOUNT_NAME="$2"
      shift 2
      ;;
    --topic)
      PUBSUB_TOPIC="$2"
      shift 2
      ;;
    --key-output)
      KEY_OUTPUT_PATH="$2"
      shift 2
      ;;
    --skip-key)
      SKIP_KEY="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$PROJECT_ID" ]]; then
  echo "--project is required" >&2
  usage
  exit 1
fi

GCLOUD_BIN="$(command -v gcloud || true)"
if [[ -z "$GCLOUD_BIN" ]]; then
  DEFAULT_GCLOUD="$HOME/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin/gcloud"
  if [[ -x "$DEFAULT_GCLOUD" ]]; then
    GCLOUD_BIN="$DEFAULT_GCLOUD"
  else
    echo "gcloud CLI not found. Install the Google Cloud SDK and ensure gcloud is on PATH." >&2
    exit 1
  fi
fi

run() {
  echo "--> gcloud $*"
  if [[ "$DRY_RUN" == "true" ]]; then
    return
  fi
  "$GCLOUD_BIN" "$@"
}

ensure_topic() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] would ensure Pub/Sub topic '$PUBSUB_TOPIC'"
    return
  fi
  if "$GCLOUD_BIN" pubsub topics describe "$PUBSUB_TOPIC" --project "$PROJECT_ID" >/dev/null 2>&1; then
    echo "Pub/Sub topic '$PUBSUB_TOPIC' already exists"
  else
    run pubsub topics create "$PUBSUB_TOPIC" --project "$PROJECT_ID" --quiet
  fi
}

ensure_service_account() {
  local email="$SERVICE_ACCOUNT_ID@$PROJECT_ID.iam.gserviceaccount.com"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] would ensure service account $email"
    return
  fi
  if "$GCLOUD_BIN" iam service-accounts describe "$email" --project "$PROJECT_ID" >/dev/null 2>&1; then
    echo "Service account $email already exists"
  else
    run iam service-accounts create "$SERVICE_ACCOUNT_ID" \
      --project "$PROJECT_ID" \
      --display-name "$SERVICE_ACCOUNT_NAME" \
      --quiet
  fi
}

add_binding() {
  local role="$1"
  run projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:$SERVICE_ACCOUNT_ID@$PROJECT_ID.iam.gserviceaccount.com" \
    --role "$role" \
    --quiet
}

SERVICE_ACCOUNT_EMAIL="$SERVICE_ACCOUNT_ID@$PROJECT_ID.iam.gserviceaccount.com"

echo "Configuring project '$PROJECT_ID' in region '$REGION'"
run config set project "$PROJECT_ID" --quiet

for svc in cloudfunctions.googleapis.com pubsub.googleapis.com secretmanager.googleapis.com; do
  run services enable "$svc" --quiet
done

ensure_topic
ensure_service_account

for role in roles/cloudfunctions.developer \
            roles/iam.serviceAccountUser \
            roles/pubsub.admin \
            roles/secretmanager.secretAccessor; do
  add_binding "$role"
done

if [[ "$SKIP_KEY" == "true" ]]; then
  echo "Skipping key creation as requested."
else
  if [[ -z "$KEY_OUTPUT_PATH" ]]; then
    KEY_OUTPUT_PATH="$(pwd)/gcp-service-account-key.json"
  fi
  if [[ -e "$KEY_OUTPUT_PATH" && "$DRY_RUN" != "true" ]]; then
    echo "Key output path '$KEY_OUTPUT_PATH' already exists. Refusing to overwrite." >&2
    exit 1
  fi
  run iam service-accounts keys create "$KEY_OUTPUT_PATH" \
    --iam-account "$SERVICE_ACCOUNT_EMAIL" \
    --project "$PROJECT_ID" \
    --quiet
  echo "Service account key written to $KEY_OUTPUT_PATH"
fi

echo "GCP bootstrap complete."