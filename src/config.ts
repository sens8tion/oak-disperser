export type Config = {
  projectId?: string;
  pubsubTopic: string;
  ingestApiKey?: string;
  allowedAudience?: string;
  allowedIssuers: string[];
  dispatchConcurrency: number;
  defaultTimeoutMs: number;
  userAgent: string;
};

const int = (value: string | undefined, fallback: number): number => {
  if (!value) {
    return fallback;
  }
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
};

const splitCsv = (value: string | undefined): string[] =>
  value ? value.split(',').map((entry) => entry.trim()).filter(Boolean) : [];

export const getConfig = (): Config => {
  const packageName = 'oak-disperser';
  const packageVersion = '0.1.0';

  return {
    projectId: process.env.GCP_PROJECT || process.env.GOOGLE_CLOUD_PROJECT,
    pubsubTopic: process.env.PUBSUB_TOPIC ?? 'action-dispersal',
    ingestApiKey: process.env.INGEST_API_KEY,
    allowedAudience: process.env.ALLOWED_AUDIENCE,
    allowedIssuers: splitCsv(process.env.ALLOWED_ISSUERS),
    dispatchConcurrency: int(process.env.DISPATCH_CONCURRENCY, 3),
    defaultTimeoutMs: int(process.env.DISPATCH_TIMEOUT_MS, 10000),
    userAgent: `${packageName}/${packageVersion}`,
  } satisfies Config;
};