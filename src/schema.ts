import { randomUUID } from 'node:crypto';
import { z } from 'zod';

const defaultStatuses = [200, 201, 202, 204] as const;
const headerSchema = z.object({}).catchall(z.string());
const objectBodySchema = z.object({}).catchall(z.unknown());

export const actionSchema = z.object({
  id: z.string().min(1, 'action id is required'),
  targetUrl: z.string().url('targetUrl must be a valid URL'),
  method: z.enum(['GET', 'POST', 'PUT', 'PATCH', 'DELETE']).default('POST'),
  headers: headerSchema.optional(),
  body: z.union([z.string(), objectBodySchema]).optional(),
  timeoutMs: z.number().int().positive().max(60000).default(10000),
  expectStatus: z
    .array(z.number().int().min(100).max(599))
    .nonempty()
    .default([...defaultStatuses]),
});

export const ingestPayloadSchema = z.object({
  correlationId: z.string().min(1).default(() => randomUUID()),
  traceId: z.string().optional(),
  requestedFor: z.string().datetime().optional(),
  metadata: z.object({}).catchall(z.unknown()).optional(),
  actions: z.array(actionSchema).min(1, 'at least one action is required'),
});

export type IngestPayload = z.infer<typeof ingestPayloadSchema>;
export type Action = z.infer<typeof actionSchema>;