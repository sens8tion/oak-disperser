import { spawn } from 'node:child_process';

const required = (name) => {
  const value = process.env[name];
  if (!value) {
    throw new Error(`deploy: missing required environment variable ${name}`);
  }
  return value;
};

const optional = (name, fallback) => process.env[name] ?? fallback;

const project = optional('GCP_PROJECT', process.env.GOOGLE_CLOUD_PROJECT);
if (!project) {
  throw new Error('deploy: set GCP_PROJECT or GOOGLE_CLOUD_PROJECT');
}

const region = optional('GCP_REGION', 'us-central1');
const topic = optional('PUBSUB_TOPIC', 'action-dispersal');

const run = (args) =>
  new Promise((resolve, reject) => {
    const child = spawn('gcloud', args, { stdio: 'inherit' });
    child.on('exit', (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`gcloud ${args.join(' ')} exited with code ${code}`));
      }
    });
    child.on('error', reject);
  });

const common = [
  'functions',
  'deploy',
  '--gen2',
  `--region=${region}`,
  '--runtime=nodejs18',
  '--source=.',
  `--project=${project}`,
];

const envVars = [
  `PUBSUB_TOPIC=${topic}`,
  process.env.INGEST_API_KEY ? `INGEST_API_KEY=${process.env.INGEST_API_KEY}` : null,
  process.env.ALLOWED_AUDIENCE ? `ALLOWED_AUDIENCE=${process.env.ALLOWED_AUDIENCE}` : null,
  process.env.ALLOWED_ISSUERS ? `ALLOWED_ISSUERS=${process.env.ALLOWED_ISSUERS}` : null,
].filter(Boolean);

const setEnvArgs = envVars.length > 0 ? [`--set-env-vars=${envVars.join(',')}`] : [];

const main = async () => {
  console.log('deploy: deploying ingest function');
  await run([
    ...common,
    'ingest',
    '--entry-point=ingest',
    '--trigger-http',
    '--no-allow-unauthenticated',
    ...setEnvArgs,
  ]);

  console.log('deploy: deploying dispatch function');
  await run([
    ...common,
    'dispatch',
    '--entry-point=dispatch',
    `--trigger-topic=${topic}`,
    ...setEnvArgs,
  ]);

  console.log('deploy: completed');
};

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});