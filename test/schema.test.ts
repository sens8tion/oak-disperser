import { describe, expect, it } from 'vitest';
import { ingestPayloadSchema } from '../src/schema';

describe('ingestPayloadSchema', () => {
  it('accepts minimal valid payloads', () => {
    const result = ingestPayloadSchema.safeParse({
      correlationId: 'abc123',
      actions: [
        {
          id: 'action-1',
          targetUrl: 'https://example.com/webhook',
        },
      ],
    });

    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.actions[0].method).toBe('POST');
      expect(result.data.actions[0].expectStatus).toContain(200);
    }
  });

  it('rejects invalid urls', () => {
    const result = ingestPayloadSchema.safeParse({
      correlationId: 'abc123',
      actions: [
        {
          id: 'action-1',
          targetUrl: 'notaurl',
        },
      ],
    });

    expect(result.success).toBe(false);
  });
});