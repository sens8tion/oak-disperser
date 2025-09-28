#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/setup-gcp.sh [options]

Options:
  --project <project-id>             (required if not using prompts)
  --region <region>                  Deployment region (default: us-central1)
  --service-account-id <id>          Service account ID (default: oak-disperser-ci)
  --service-account-name <name>      Service account display name (default: Oak Disperser CI)
  --topic <topic>                    Pub/Sub topic name (default: action-dispersal)
  --key-output <path>                Where to write the generated key JSON (default: ./gcp-service-account-key.json)
  --skip-key                         Do not create a service account key
  --dry-run                          Print commands without executing them
  --configure-github-secrets         Push secrets to GitHub using gh CLI
  --github-repo <owner/repo>         Explicit repo for secrets (defaults to origin remote)
  -h, --help                         Show this message
USAGE
}

PROMPT=true
PROJECT_ID=""
REGION="us-central1"
SERVICE_ACCOUNT_ID="oak-disperser-ci"
SERVICE_ACCOUNT_NAME="Oak Disperser CI"
PUBSUB_TOPIC="action-dispersal"
KEY_OUTPUT_PATH=""
SKIP_KEY=false
DRY_RUN=false
CONFIGURE_GITHUB=false
GITHUB_REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_ID="$2"
      PROMPT=false
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
      SKIP_KEY=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --configure-github-secrets)
      CONFIGURE_GITHUB=true
      shift
      ;;
    --github-repo)
      GITHUB_REPO="$2"
      shift 2
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

prompt_if_missing() {
  local value="$1"
  local prompt="$2"
  local default="$3"
  if [[ -n "$value" ]]; then
    echo "$value"
    return
  fi
  if [[ "$PROMPT" == false && -z "$default" ]]; then
    echo "Error: $prompt is required" >&2
    exit 1
  fi
  local message="$prompt"
  if [[ -n "$default" ]]; then
    message+=" [$default]"
  fi
  read -r -p "$message: " input || exit 1
  if [[ -z "$input" ]]; then
    if [[ -n "$default" ]]; then
      echo "$default"
    else
      echo "Error: $prompt is required" >&2
      exit 1
    fi
  else
    echo "$input"
  fi
}

PROJECT_ID="$(prompt_if_missing "$PROJECT_ID" 'Enter GCP project id' '')"
REGION="$(prompt_if_missing "$REGION" 'Enter region' "$REGION")"
PUBSUB_TOPIC="$(prompt_if_missing "$PUBSUB_TOPIC" 'Enter Pub/Sub topic' "$PUBSUB_TOPIC")"

if [[ "$CONFIGURE_GITHUB" == true && "$SKIP_KEY" == true ]]; then
  echo "Cannot configure GitHub secrets when --skip-key is used." >&2
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

ensure_gcloud_login() {
  echo "Checking gcloud authentication status..."
  if [[ "$DRY_RUN" == true ]]; then
    return
  fi
  local active
  active="$($GCLOUD_BIN auth list --filter='status:ACTIVE' --format='value(account)' 2>/dev/null || true)"
  if [[ -z "$active" ]]; then
    echo "No active gcloud account detected. Launching gcloud auth login."
    "$GCLOUD_BIN" auth login
  fi
}

run() {
  echo "--> gcloud $*"
  if [[ "$DRY_RUN" == true ]]; then
    return
  fi
  "$GCLOUD_BIN" "$@"
}

ensure_topic() {
  if [[ "$DRY_RUN" == true ]]; then
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
  if [[ "$DRY_RUN" == true ]]; then
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

ensure_gcloud_login

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

if [[ "$SKIP_KEY" == true ]]; then
  echo "Skipping key creation as requested."
else
  if [[ -z "$KEY_OUTPUT_PATH" ]]; then
    KEY_OUTPUT_PATH="$(pwd)/gcp-service-account-key.json"
  fi
  if [[ -e "$KEY_OUTPUT_PATH" && "$DRY_RUN" != true ]]; then
    echo "Key output path '$KEY_OUTPUT_PATH' already exists. Refusing to overwrite." >&2
    exit 1
  fi
  run iam service-accounts keys create "$KEY_OUTPUT_PATH" \
    --iam-account "$SERVICE_ACCOUNT_EMAIL" \
    --project "$PROJECT_ID" \
    --quiet
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] would write service account key to $KEY_OUTPUT_PATH"
  else
    echo "Service account key written to $KEY_OUTPUT_PATH"
  fi
fi

resolve_repo() {
  if [[ -n "$GITHUB_REPO" ]]; then
    echo "$GITHUB_REPO"
    return
  fi
  local url
  url=$(git config --get remote.origin.url 2>/dev/null || true)
  if [[ "$url" =~ github.com[:/](.+)/([^/.]+)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else
    echo "";
  fi
}

if [[ "$CONFIGURE_GITHUB" == true ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] would configure GitHub secrets (skipped)."
  else
    if [[ "$SKIP_KEY" == true ]]; then
      echo "Cannot configure secrets without a key file. Remove --skip-key." >&2
      exit 1
    fi
    if [[ ! -f "$KEY_OUTPUT_PATH" ]]; then
      echo "Service account key file '$KEY_OUTPUT_PATH' not found." >&2
      exit 1
    fi
    GH_BIN=$(command -v gh || true)
    if [[ -z "$GH_BIN" ]]; then
      echo "GitHub CLI (gh) not found. Install it before using --configure-github-secrets." >&2
      exit 1
    fi
    if ! "$GH_BIN" auth status >/dev/null 2>&1; then
      echo "GitHub CLI is not authenticated. Launching gh auth login."
      "$GH_BIN" auth login
    fi
    REPO="$(resolve_repo)"
    if [[ -z "$REPO" ]]; then
      echo "Unable to determine GitHub repo. Use --github-repo owner/repo." >&2
      exit 1
    fi
    echo "Configuring GitHub secrets in $REPO"
    "$GH_BIN" secret set GCP_SA_KEY --repo "$REPO" --body-file "$KEY_OUTPUT_PATH"
    "$GH_BIN" secret set GCP_PROJECT --repo "$REPO" --body "$PROJECT_ID"
    read -r -p "GCP region for secret [$REGION]: " region_secret
    region_secret=${region_secret:-$REGION}
    "$GH_BIN" secret set GCP_REGION --repo "$REPO" --body "$region_secret"
    read -r -p "Pub/Sub topic for secret [$PUBSUB_TOPIC]: " topic_secret
    topic_secret=${topic_secret:-$PUBSUB_TOPIC}
    "$GH_BIN" secret set PUBSUB_TOPIC --repo "$REPO" --body "$topic_secret"
    read -r -p "Optional INGEST_API_KEY (blank to skip): " ingest_key
    if [[ -n "$ingest_key" ]]; then
      "$GH_BIN" secret set INGEST_API_KEY --repo "$REPO" --body "$ingest_key"
    fi
    read -r -p "Optional ALLOWED_AUDIENCE (blank to skip): " audience
    if [[ -n "$audience" ]]; then
      "$GH_BIN" secret set ALLOWED_AUDIENCE --repo "$REPO" --body "$audience"
    fi
    read -r -p "Optional ALLOWED_ISSUERS (comma separated, blank to skip): " issuers
    if [[ -n "$issuers" ]]; then
      "$GH_BIN" secret set ALLOWED_ISSUERS --repo "$REPO" --body "$issuers"
    fi
  fi
fi

echo "GCP bootstrap complete."