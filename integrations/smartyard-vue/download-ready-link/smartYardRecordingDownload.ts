export type SmartYardApiGet = <T>(path: string, params?: object) => Promise<T>;

export type SmartYardRecordingDownloadRequest = {
  apiGet: SmartYardApiGet;
  cameraId: string | number;
  from: string;
  to: string;
  signal?: AbortSignal;
  timeoutMs?: number;
  pollIntervalMs?: number;
};

const PANEL_ID = "newdomofon-smartyard-download";
const DEFAULT_TIMEOUT_MS = 15 * 60 * 1000;
const DEFAULT_POLL_INTERVAL_MS = 2000;

function abortError(): DOMException {
  return new DOMException("Download preparation was cancelled", "AbortError");
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(abortError());

    const timer = window.setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);

    const onAbort = () => {
      window.clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      reject(abortError());
    };

    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

function retryableStatus(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const response = (error as { response?: { status?: unknown } }).response;
  const status = Number(response?.status);
  return [202, 204, 404, 409, 425, 429].includes(status);
}

export function extractSmartYardDownloadUrl(payload: unknown): string | null {
  const visited = new WeakSet<object>();

  const scan = (value: unknown, depth: number): string | null => {
    if (depth > 6 || value == null) return null;

    if (typeof value === "string") {
      const text = value.trim();
      if (!text) return null;
      if (/^(?:https?:\/\/|\/|\.\/|\.\.\/)/i.test(text)) return text;
      return null;
    }

    if (Array.isArray(value)) {
      for (const item of value) {
        const match = scan(item, depth + 1);
        if (match) return match;
      }
      return null;
    }

    if (typeof value !== "object") return null;
    if (visited.has(value)) return null;
    visited.add(value);

    const object = value as Record<string, unknown>;
    for (const key of [
      "url",
      "downloadUrl",
      "download_url",
      "fileUrl",
      "file_url",
      "href",
      "link",
      "file",
      "path",
      "data",
      "result",
    ]) {
      if (!(key in object)) continue;
      const match = scan(object[key], depth + 1);
      if (match) return match;
    }

    return null;
  };

  return scan(payload, 0);
}

function normalizeDownloadUrl(rawUrl: string): string {
  return new URL(rawUrl, window.location.href).toString();
}

export async function prepareSmartYardRecordingDownload({
  apiGet,
  cameraId,
  from,
  to,
  signal,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  pollIntervalMs = DEFAULT_POLL_INTERVAL_MS,
}: SmartYardRecordingDownloadRequest): Promise<string> {
  if (signal?.aborted) throw abortError();

  const recordId = await apiGet<string | number>("/cctv/recPrepare", {
    id: cameraId,
    from,
    to,
  });

  if (recordId === undefined || recordId === null || String(recordId).trim() === "") {
    throw new Error("SmartYard did not return a recording preparation id");
  }

  const deadline = Date.now() + Math.max(10_000, timeoutMs);
  const interval = Math.max(500, pollIntervalMs);

  while (Date.now() <= deadline) {
    if (signal?.aborted) throw abortError();

    try {
      const response = await apiGet<unknown>("/cctv/recDownload", { id: recordId });
      const rawUrl = extractSmartYardDownloadUrl(response);
      if (rawUrl) return normalizeDownloadUrl(rawUrl);
    } catch (error) {
      if (!retryableStatus(error)) throw error;
    }

    await sleep(interval, signal);
  }

  throw new Error("SmartYard did not prepare the download link within 15 minutes");
}

function ensurePanel(): {
  root: HTMLDivElement;
  title: HTMLDivElement;
  message: HTMLDivElement;
  link: HTMLAnchorElement;
} {
  let root = document.getElementById(PANEL_ID) as HTMLDivElement | null;
  if (!root) {
    root = document.createElement("div");
    root.id = PANEL_ID;
    root.setAttribute("role", "status");
    root.setAttribute("aria-live", "polite");
    Object.assign(root.style, {
      position: "fixed",
      right: "18px",
      bottom: "18px",
      zIndex: "2147483647",
      width: "min(430px, calc(100vw - 36px))",
      padding: "16px",
      borderRadius: "14px",
      background: "#17202b",
      color: "#ffffff",
      boxShadow: "0 16px 50px rgba(0,0,0,.38)",
      fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
      fontSize: "14px",
      lineHeight: "1.4",
    });

    root.innerHTML = `
      <button type="button" data-role="close" aria-label="Закрыть" style="position:absolute;right:10px;top:8px;border:0;background:transparent;color:inherit;font-size:22px;cursor:pointer">×</button>
      <div data-role="title" style="font-weight:700;padding-right:28px"></div>
      <div data-role="message" style="margin-top:6px;opacity:.88"></div>
      <a data-role="link" target="_blank" rel="noopener noreferrer" style="display:none;margin-top:12px;padding:10px 12px;border-radius:10px;background:#298bff;color:#fff;text-decoration:none;font-weight:700;text-align:center">Скачать подготовленное видео</a>
    `;

    root.querySelector<HTMLButtonElement>('[data-role="close"]')?.addEventListener("click", () => {
      root?.remove();
    });
    document.body.appendChild(root);
  }

  return {
    root,
    title: root.querySelector<HTMLDivElement>('[data-role="title"]')!,
    message: root.querySelector<HTMLDivElement>('[data-role="message"]')!,
    link: root.querySelector<HTMLAnchorElement>('[data-role="link"]')!,
  };
}

export function showSmartYardDownloadPending(): void {
  const panel = ensurePanel();
  panel.title.textContent = "Подготовка видео";
  panel.message.textContent = "SmartYard формирует MP4. Эта панель обновится автоматически, когда ссылка будет готова.";
  panel.link.style.display = "none";
  panel.link.removeAttribute("href");
}

export function showSmartYardDownloadReady(url: string): void {
  const panel = ensurePanel();
  panel.title.textContent = "Видео готово";
  panel.message.textContent = "Ссылка сохранится в этой панели, пока вы её не закроете.";
  panel.link.href = normalizeDownloadUrl(url);
  panel.link.style.display = "block";
  panel.link.focus({ preventScroll: true });
}

export function showSmartYardDownloadError(error: unknown): void {
  const panel = ensurePanel();
  panel.title.textContent = "Не удалось подготовить видео";
  panel.message.textContent = error instanceof Error ? error.message : String(error);
  panel.link.style.display = "none";
  panel.link.removeAttribute("href");
}
