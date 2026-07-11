import type { NextFunction, Request, Response } from 'express';
import { ZodError } from 'zod';

function errorCode(error: unknown): string {
  if (!error || typeof error !== 'object') return '';
  const candidate = error as { code?: unknown; errno?: unknown };
  return String(candidate.code || candidate.errno || '');
}

function errorStatus(error: unknown): number | null {
  if (!error || typeof error !== 'object') return null;
  const candidate = error as { status?: unknown; statusCode?: unknown };
  const value = Number(candidate.status || candidate.statusCode);
  return Number.isInteger(value) && value >= 400 && value <= 599 ? value : null;
}

function isDiskFullError(error: unknown): boolean {
  const code = errorCode(error).toUpperCase();
  if (code === 'ENOSPC' || code === '53100') return true;
  const message = error instanceof Error ? error.message : String(error || '');
  return /no space left on device|disk full|could not extend file/i.test(message);
}

export function errorHandler(error: unknown, _req: Request, res: Response, _next: NextFunction) {
  console.error(error);
  if (error instanceof ZodError) {
    return res.status(400).json({ error: 'Validation error', details: error.flatten() });
  }
  if (isDiskFullError(error)) {
    res.setHeader('retry-after', '60');
    return res.status(507).json({
      error: 'Insufficient storage',
      code: 'DISK_FULL',
      retryable: true
    });
  }
  const message = error instanceof Error ? error.message : 'Internal server error';
  return res.status(errorStatus(error) || 500).json({ error: message });
}
