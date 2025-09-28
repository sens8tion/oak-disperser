import { readFileSync } from 'node:fs';

const forbiddenHooks = new Set([
  'preinstall',
  'install',
  'postinstall',
  'prepare',
  'prepublish',
  'postpublish',
]);

const offenders = [];

const scanPackagesEntry = (packages) => {
  if (!packages) return;
  for (const [name, meta] of Object.entries(packages)) {
    if (!meta || typeof meta !== 'object') continue;
    if (name === '') continue; // root project scripts are intentional
    const scripts = meta.scripts;
    if (!scripts) continue;
    const triggers = Object.keys(scripts).filter((script) => forbiddenHooks.has(script));
    if (triggers.length > 0) {
      offenders.push({ name, triggers, scripts });
    }
  }
};

const scanDependencies = (dependencies, lineage = []) => {
  if (!dependencies) return;
  for (const [name, meta] of Object.entries(dependencies)) {
    if (!meta || typeof meta !== 'object') continue;
    const scripts = meta.scripts;
    if (scripts) {
      const triggers = Object.keys(scripts).filter((script) => forbiddenHooks.has(script));
      if (triggers.length > 0) {
        offenders.push({ name: [...lineage, name].join(' > '), triggers, scripts });
      }
    }
    scanDependencies(meta.dependencies, [...lineage, name]);
  }
};

try {
  const raw = readFileSync(new URL('../package-lock.json', import.meta.url), 'utf8');
  const lock = JSON.parse(raw);
  scanPackagesEntry(lock.packages);
  scanDependencies(lock.dependencies);
} catch (error) {
  console.error('check-install-scripts: failed to read package-lock.json', error);
  process.exit(1);
}

if (offenders.length > 0) {
  console.error('check-install-scripts: forbidden lifecycle scripts detected');
  for (const offender of offenders) {
    console.error(` - ${offender.name}: ${offender.triggers.join(', ')}`);
  }
  process.exit(1);
}

console.log('check-install-scripts: package-lock is free of forbidden lifecycle hooks');