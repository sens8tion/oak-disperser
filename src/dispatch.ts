import { Buffer } from 'node:buffer';
import { getConfig } from './config';
import type { Action, IngestPayload } from './schema';
import { ingestPayloadSchema } from './schema';

type PubSubMessage = {
  data?: string;
  messageId?: string;
  attributes?: Record<string, string>;
};

type PubSubCloudEvent = {
  data?: {
    message?: PubSubMessage;
    subscription?: string;
  };
  id?: string;
  time?: string;
};

const config = getConfig();

type ExecutionResult = {
  id: string;
  ok: boolean;
  status?: number;
  error?: string;
};

const pickTimeout = (action: Action): number => action.timeoutMs ?? config.defaultTimeoutMs;

const asBody = (action: Action): string | undefined => {
  if (typeof action.body === 'string') {
    return action.body;
  }
  if (action.body && typeof action.body === 'object') {
    return JSON.stringify(action.body);
  }
  return undefined;
};

const executeAction = async (action: Action): Promise<ExecutionResult> => {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), pickTimeout(action));

  try {
    const headers: Record<string, string> = action.headers ? { ...action.headers } : {};
    headers['user-agent'] = headers['user-agent'] ?? config.userAgent;

    const body = asBody(action);
    if (body && !headers['content-type']) {
      headers['content-type'] = 'application/json';
    }

    const response = await fetch(action.targetUrl, {
      method: action.method,
      headers,
      body,
      signal: controller.signal,
    });

    const ok = action.expectStatus.includes(response.status);
    if (!ok) {
      const text = await response.text().catch(() => '[no-body]');
      return {
        id: action.id,
        ok: false,
        status: response.status,
        error: `unexpected status ${response.status}: ${text.slice(0, 200)}`,
      };
    }

    return { id: action.id, ok: true, status: response.status };
  } catch (error) {
    return {
      id: action.id,
      ok: false,
      error: error instanceof Error ? error.message : 'unknown error',
    };
  } finally {
    clearTimeout(timeout);
  }
};

const decodeMessage = (message: PubSubMessage | undefined): IngestPayload | null => {
  if (!message?.data) {
    return null;
  }
  try {
    const json = Buffer.from(message.data, 'base64').toString('utf8');
    const parsed = JSON.parse(json);
    const result = ingestPayloadSchema.safeParse(parsed);
    if (!result.success) {
      console.error('dispatch: invalid payload', result.error.flatten());
      return null;
    }
    return result.data;
  } catch (error) {
    console.error('dispatch: failed to parse message', error);
    return null;
  }
};

const runWithConcurrency = async (actions: Action[]): Promise<ExecutionResult[]> => {
  const executing = new Set<Promise<ExecutionResult>>();
  const results: ExecutionResult[] = [];

  for (const action of actions) {
    const task = executeAction(action).then((result) => {
      results.push(result);
      return result;
    });

    executing.add(task.finally(() => executing.delete(task)));

    if (executing.size >= config.dispatchConcurrency) {
      await Promise.race(executing);
    }
  }

  await Promise.allSettled(executing);
  return results;
};

export const dispatch = async (event: PubSubCloudEvent): Promise<void> => {
  const payload = decodeMessage(event.data?.message);
  if (!payload) {
    console.warn('dispatch: no payload decoded');
    return;
  }

  const results = await runWithConcurrency(payload.actions);
  const failed = results.filter((result) => !result.ok);

  if (failed.length > 0) {
    console.error('dispatch: some actions failed', { correlationId: payload.correlationId, failed });
    throw new Error(`dispatch failed for ${failed.length} action(s)`);
  }

  console.info('dispatch: all actions delivered', {
    correlationId: payload.correlationId,
    count: results.length,
  });
};