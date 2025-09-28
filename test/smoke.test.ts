import type { Request, Response } from 'express';
import { afterEach, describe, expect, it, vi } from 'vitest';

const originalEnv = { ...process.env };

afterEach(() => {
  process.env = { ...originalEnv };
  vi.restoreAllMocks();
  vi.resetModules();
  vi.unstubAllGlobals();
});

describe('smoke', () => {
  it('ingest publishes payload to pubsub and returns 202', async () => {
    vi.resetModules();

    const publishMock = vi.fn(async () => 'msg-123');
    await vi.doMock('@google-cloud/pubsub', () => ({
      PubSub: class {
        topic() {
          return { publishMessage: publishMock };
        }
      }
    }));

    process.env = {
      ...originalEnv,
      PUBSUB_TOPIC: 'smoke-topic',
      INGEST_API_KEY: 'secret-key',
    };

    const { ingest } = await import('../src/ingest');

    const req = {
      method: 'POST',
      body: {
        correlationId: 'corr-1',
        actions: [
          {
            id: 'action-1',
            targetUrl: 'https://example.com/hook',
          },
        ],
      },
      is: vi.fn(() => true),
      get: vi.fn((header: string) => (header.toLowerCase() === 'x-api-key' ? 'secret-key' : undefined)),
    } satisfies Partial<Request> as Request;

    const res = {
      status: vi.fn().mockReturnThis(),
      json: vi.fn(),
      setHeader: vi.fn(),
    } satisfies Partial<Response> as Response;

    await ingest(req, res);

    expect(publishMock).toHaveBeenCalledTimes(1);
    expect(res.status).toHaveBeenCalledWith(202);
    expect(res.json).toHaveBeenCalledWith(
      expect.objectContaining({ status: 'accepted', correlationId: 'corr-1' }),
    );
  });

  it('dispatch performs outbound call for each action', async () => {
    vi.resetModules();

    const fetchMock = vi.fn(async () => ({
      status: 200,
      text: async () => 'ok',
    }));
    vi.stubGlobal('fetch', fetchMock);

    process.env = {
      ...originalEnv,
      DISPATCH_CONCURRENCY: '2',
    };

    const { dispatch } = await import('../src/dispatch');

    const payload = {
      correlationId: 'corr-2',
      actions: [
        {
          id: 'a-1',
          targetUrl: 'https://example.com/a',
          method: 'POST',
        },
      ],
    };

    const encoded = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64');

    await dispatch({
      data: {
        message: {
          data: encoded,
        },
      },
    });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0]?.[0]).toBe('https://example.com/a');
  });
});