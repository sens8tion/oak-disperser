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

Install the Google Cloud SDK (for example):

```powershell
winget install Google.CloudSDK
```

The helper scripts prompt for missing values, trigger `gcloud auth login` when needed, and can push GitHub secrets automatically.

**Windows / PowerShell**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ./scripts/setup-gcp.ps1 -ConfigureGithubSecrets
```

**macOS / Linux**

```bash
pwsh -NoProfile -File ./scripts/setup-gcp.ps1 -ConfigureGithubSecrets
```

Additional switches:

- `-ProjectId/--project`, `-BaseProjectName/--base-name`, `-Region/--region`, `-KeyOutputPath/--key-output` to pre-supply values
- `-BillingAccountId/--billing-account` to link the project to a billing account
- `-FreeTierThreshold/--free-tier-threshold` to adjust the automatic free-tier guard (default 0.8)
- `-StatusWebhookUri/--status-webhook` to receive status notifications for key events
- `-DryRun/--dry-run` to print the planned commands without executing
- `-SkipKey/--skip-key` to skip service-account key creation
- `-ConfigureGithubSecrets/--configure-github-secrets` to update GitHub Actions secrets automatically

The bootstrap flow:

- ensures you are authenticated with `gcloud`
- creates the project if it does not already exist (deriving an `-oak-disperser` suffix)
- enables Cloud Functions, Pub/Sub, and Secret Manager APIs
- creates (or reuses) the `action-dispersal` Pub/Sub topic
- provisions the CI service account with required roles
- checks Cloud Functions executions against the free-tier threshold and aborts if you are close to the limit
- optionally generates a key file and uploads `GCP_SA_KEY`, `GCP_PROJECT`, `GCP_REGION`, `PUBSUB_TOPIC`, and optional auth secrets via the GitHub CLI

If you prefer to manage secrets manually, omit the `ConfigureGithubSecrets` / `--configure-github-secrets` flag and upload the generated key to GitHub Actions yourself.





