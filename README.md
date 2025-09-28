# Oak Disperser

Oak Disperser is a stateless Google Cloud workflow that accepts authorised JSON payloads and fans them out to remote HTTP endpoints to trigger daily actions, refresh lists, or perform lightweight automations. Everything stays within free-tier friendly services (Cloud Functions 2nd gen + Pub/Sub), and no long-lived state is maintained.

## Architecture

- **Ingest function (`ingest`)** — HTTPS Cloud Function (Node.js 18, TypeScript). It authenticates the caller (API key or Google ID token), validates the JSON payload, and publishes a normalised message to Pub/Sub.
- **Dispatch function (`dispatch`)** — Pub/Sub-triggered Cloud Function that pulls each action from the message and executes the HTTP calls with per-action timeouts and status checks.
- **Pub/Sub topic (`action-dispersal`)** — The only hand-off between functions; messages contain everything required to complete each downstream call, so no database or cache is needed.
- **Secrets & config** — Environment variables (backed by Secret Manager in production) store API keys, allowed Google audiences/issuers, and any downstream credentials. Because the system is stateless, replays can be driven by re-publishing the same payload.

## Payload contract

```jsonc
{
  "correlationId": "string",        // optional, generated when omitted
  "traceId": "string",              // optional tracing identifier
  "requestedFor": "ISO timestamp",  // optional logical execution time
  "metadata": { "key": "value" }, // optional passthrough metadata
  "actions": [
    {
      "id": "action-1",
      "targetUrl": "https://example.com/webhook",
      "method": "POST",             // GET | POST | PUT | PATCH | DELETE
      "headers": { "x-api-key": "secret" },
      "body": { "any": "json" },   // or raw string
      "timeoutMs": 10000,
      "expectStatus": [200, 202]
    }
  ]
}
```

All fields other than `actions[].targetUrl` and `actions[].id` are optional; defaults enforce `POST` with a 10s timeout and 2xx success codes.

## Local development

```bash
npm ci
npm run lint
npm run test
npm run build
```

Run the smoke suite (mocks Pub/Sub and outbound calls):

```bash
npm run smoke
```

To emulate the HTTP function locally:

```bash
npx functions-framework --target=ingest --source=dist/index.js --signature-type=http
```

Deployable artefacts live in `dist/` after `npm run build`.

## Configuration

Environment variables recognised by the functions:

- `PUBSUB_TOPIC` (default `action-dispersal`)
- `INGEST_API_KEY` (optional shared secret for callers)
- `ALLOWED_AUDIENCE` (optional Google ID token audience)
- `ALLOWED_ISSUERS` (comma-separated issuers, optional)
- `DISPATCH_CONCURRENCY` (default `3`)
- `DISPATCH_TIMEOUT_MS` (default `10000`)

When deploying via GitHub Actions, set the corresponding repository secrets (`GCP_PROJECT`, `GCP_REGION`, `PUBSUB_TOPIC`, `INGEST_API_KEY`, `ALLOWED_AUDIENCE`, `ALLOWED_ISSUERS`, `GCP_SA_KEY`).

## Deployment

The helper script `npm run deploy` wraps `gcloud functions deploy` for both entrypoints:

1. Enable services: `gcloud services enable cloudfunctions.googleapis.com pubsub.googleapis.com secretmanager.googleapis.com`
2. Create the topic: `gcloud pubsub topics create action-dispersal`
3. Deploy from a built workspace: `npm run build && npm run deploy`

The ingest function disallows unauthenticated calls by default; provide an API key or Google auth audience during deployment.

## CI/CD pipeline

`.github/workflows/ci.yml` enforces:

- `npm ci --ignore-scripts` so third-party packages never execute install hooks
- `npm run check:lockfiles` to fail the build if any dependency advertises install/postinstall scripts
- Linting, type checking, tests, and TypeScript builds
- `npm audit --omit=dev --audit-level=high`
- A gated deploy job (runs on `main`) that authenticates with GCP and executes `npm run deploy`

Only after every check passes does the pipeline attempt deployment, giving you a hardened publish path.
### GCP Bootstrap

Install the Google Cloud SDK (for example on Windows: winget install Google.CloudSDK). Then bootstrap the project resources and CI service account:

`powershell
# Windows / PowerShell Core
gcloud --version # ensure the CLI is available
pwsh -NoProfile -File ./scripts/setup-gcp.ps1 -ProjectId <your-project-id> -Region us-central1 -KeyOutputPath ./gcp-sa-key.json
`
`ash
# macOS / Linux
./scripts/setup-gcp.sh --project <your-project-id> --region us-central1 --key-output ./gcp-sa-key.json
`

The scripts will:
- enable Cloud Functions, Pub/Sub, and Secret Manager APIs
- create the ction-dispersal Pub/Sub topic (customisable via flag)
- provision a CI service account with the necessary roles
- optionally generate a key file for GitHub Actions (--skip-key to opt out)

Upload the generated key to the repository secrets as GCP_SA_KEY, and set GCP_PROJECT, GCP_REGION, and any optional runtime secrets. Subsequent pushes to main will deploy automatically once these values are present.

