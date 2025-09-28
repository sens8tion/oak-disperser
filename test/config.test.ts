import { describe, expect, it } from 'vitest';
import { getConfig } from '../src/config';

describe('getConfig', () => {
  it('provides defaults when environment variables absent', () => {
    const config = getConfig();
    expect(config.pubsubTopic).toBe('action-dispersal');
    expect(config.dispatchConcurrency).toBeGreaterThan(0);
    expect(config.userAgent).toMatch(/oak-disperser/);
  });
});