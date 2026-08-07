#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = 'HIKVISION_SMARTYARD_UPSTREAM_ABORT'


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'{label}: expected one source fragment, found {count}')
    return text.replace(old, new, 1)


def patch_gateway(path: Path) -> None:
    text = path.read_text(encoding='utf-8')
    if MARKER in text:
        print('Hikvision SmartYard upstream abort propagation already prepared')
        return

    old_node_request = r'''async function nodeRequest(context, pathname, req, timeoutMs = 30000, init = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const headers = {
    accept: String(req.headers.accept || '*/*'),
    'user-agent': `newdomofon-smartyard-${VERSION}`,
    ...(init.headers || {})
  };
  if (req.headers.range) headers.range = String(req.headers.range);
  try {
    return await fetch(`${String(context.node.url).replace(/\/+$/, '')}${pathname}`, {
      ...init,
      method: init.method || (req.method === 'HEAD' ? 'HEAD' : 'GET'),
      signal: controller.signal,
      headers
    });
  } finally {
    clearTimeout(timer);
  }
}'''
    new_node_request = r'''// HIKVISION_SMARTYARD_UPSTREAM_ABORT
async function nodeRequest(context, pathname, req, timeoutMs = 30000, init = {}) {
  const controller = new AbortController();
  const externalSignal = init.signal;
  const abortFromExternal = () => {
    if (!controller.signal.aborted) controller.abort(externalSignal?.reason);
  };
  if (externalSignal?.aborted) abortFromExternal();
  else externalSignal?.addEventListener('abort', abortFromExternal, { once: true });

  const timer = setTimeout(() => {
    if (!controller.signal.aborted) controller.abort(new Error(`Hikvision upstream timeout after ${timeoutMs} ms`));
  }, timeoutMs);
  const headers = {
    accept: String(req.headers.accept || '*/*'),
    'user-agent': `newdomofon-smartyard-${VERSION}`,
    ...(init.headers || {})
  };
  if (req.headers.range) headers.range = String(req.headers.range);
  const fetchInit = { ...init };
  delete fetchInit.signal;
  try {
    return await fetch(`${String(context.node.url).replace(/\/+$/, '')}${pathname}`, {
      ...fetchInit,
      method: init.method || (req.method === 'HEAD' ? 'HEAD' : 'GET'),
      signal: controller.signal,
      headers
    });
  } finally {
    clearTimeout(timer);
    externalSignal?.removeEventListener('abort', abortFromExternal);
  }
}'''
    text = replace_once(text, old_node_request, new_node_request, 'abort-aware nodeRequest')

    old_segment = r'''  if (mediaPath.startsWith('__hik/')) {
    const encoded = mediaPath.slice('__hik/'.length).split('/')[0];
    const decoded = decodeOpaqueUpstreamPath(encoded);
    if (!decoded) return sendJson(res, 400, { error: 'Invalid Hikvision media segment path' });
    const upstream = withToken(decoded, context.upstream_token);
    const response = await nodeRequest(context, upstream, req, 30000);
    return sendNodeResponse(req, res, response, stream, externalToken, 'hikvision-segment', upstream);
  }'''
    new_segment = r'''  if (mediaPath.startsWith('__hik/')) {
    const encoded = mediaPath.slice('__hik/'.length).split('/')[0];
    const decoded = decodeOpaqueUpstreamPath(encoded);
    if (!decoded) return sendJson(res, 400, { error: 'Invalid Hikvision media segment path' });
    const upstream = withToken(decoded, context.upstream_token);
    const downstream = new AbortController();
    const abortUpstream = () => {
      if (!downstream.signal.aborted) downstream.abort(new Error('SmartYard downstream request closed'));
    };
    const onResponseClose = () => {
      if (!res.writableEnded) abortUpstream();
    };
    req.once('aborted', abortUpstream);
    res.once('close', onResponseClose);
    try {
      const response = await nodeRequest(context, upstream, req, 30000, { signal: downstream.signal });
      if (downstream.signal.aborted || res.destroyed) return;
      return sendNodeResponse(req, res, response, stream, externalToken, 'hikvision-segment', upstream);
    } catch (error) {
      if (downstream.signal.aborted || res.destroyed) return;
      throw error;
    } finally {
      req.off('aborted', abortUpstream);
      res.off('close', onResponseClose);
    }
  }'''
    text = replace_once(text, old_segment, new_segment, 'opaque segment downstream abort propagation')

    if MARKER not in text or "req.once('aborted', abortUpstream)" not in text or 'signal: downstream.signal' not in text:
        raise RuntimeError('Hikvision SmartYard upstream abort markers are incomplete')

    path.write_text(text, encoding='utf-8')
    print('Hikvision SmartYard now propagates aborted __hik requests to the Hik node')
    print('Obsolete browser seek requests now cancel the in-flight upstream fetch')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--project-dir', default='.')
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    patch_gateway(root / 'smartyard-compat-proxy/server-hikvision-gateway.js')


if __name__ == '__main__':
    main()
