<template>
  <v-container fluid class="pa-6 player-page">
    <div class="d-flex align-center mb-4 flex-wrap ga-2">
      <div>
        <h1 class="text-h4">{{ camera?.name || 'Камера' }}</h1>
        <div class="text-medium-emphasis">
          {{ camera?.stream_name || 'stream_name не загружен' }}
          <span v-if="camera?.dvr_server_name"> · {{ camera.dvr_server_name }}</span>
        </div>
      </div>
      <v-spacer />
      <v-btn prepend-icon="mdi-refresh" :loading="loading" @click="reloadPlayer">Обновить</v-btn>
      <v-btn variant="tonal" to="/cameras">К камерам</v-btn>
    </div>

    <v-alert v-if="error" type="error" variant="tonal" class="mb-4" closable @click:close="error = ''">
      {{ error }}
    </v-alert>

    <v-row>
      <v-col cols="12" lg="9">
        <v-card class="player-card">
          <div ref="playerRoot" class="player-kit-host">
            <div v-if="loading" class="player-loading">Загрузка плеера...</div>
          </div>
          <div v-if="archivePreparing" class="archive-preparing">
            <v-progress-circular indeterminate color="primary" />
            <span>Готовим архивный фрагмент...</span>
          </div>
        </v-card>
      </v-col>

      <v-col cols="12" lg="3">
        <v-card class="mb-4">
          <v-card-title>Статус</v-card-title>
          <v-card-text>
            <v-chip :color="status?.recording ? 'success' : 'error'">
              {{ status?.recording ? 'recording' : 'offline' }}
            </v-chip>
            <pre class="mt-4 status-json">{{ status }}</pre>
          </v-card-text>
        </v-card>

        <v-card>
          <v-card-title>Технические данные</v-card-title>
          <v-card-text>
            <div class="mb-2"><strong>Stream:</strong> {{ camera?.stream_name || '—' }}</div>
            <div class="mb-2"><strong>Node:</strong> {{ camera?.dvr_server_name || '—' }}</div>
            <div class="mb-2"><strong>Архив:</strong> {{ camera?.retention_days || '—' }} дней</div>
            <div class="mb-2"><strong>Хранение:</strong> локальный архив Node</div>
            <div class="mb-2"><strong>Live:</strong> <code>{{ tokenlessLiveUrl }}</code></div>
            <div><strong>Archive:</strong> <code>{{ tokenlessArchiveUrl }}</code></div>
          </v-card-text>
        </v-card>
      </v-col>
    </v-row>
  </v-container>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { api } from '../api';

type PlayerKitInstance = {
  mount(): Promise<void>;
  destroy(): void;
};

type PlayerKitWindow = Window & {
  NewDomofonPlayer?: {
    create(config: Record<string, unknown>): PlayerKitInstance;
    createNewDomofonPlayer?: (config: Record<string, unknown>) => PlayerKitInstance;
  };
};

const PLAYER_KIT_SCRIPT = '/player-kit/newdomofon-player.iife.js';
const PLAYER_KIT_SHIM = '/player-kit/newdomofon-player-global-shim.js';
const PLAYER_KIT_CSS = '/player-kit/newdomofon-player.css';

const route = useRoute();
const camera = ref<any>(null);
const status = ref<any>(null);
const error = ref('');
const loading = ref(false);
const archivePreparing = ref(false);
const playerRoot = ref<HTMLElement | null>(null);
let player: PlayerKitInstance | null = null;
let latestArchiveRanges: Array<{ startMs: number; endMs: number }> = [];
let latestArchiveRangesLoadedAt = 0;
let latestArchiveRangesKey = '';
let assetsPromise: Promise<void> | null = null;
let archiveSeekGeneration = 0;
let archiveSeekAbortController: AbortController | null = null;

const NODE_ARCHIVE_MIN_PLAY_SECONDS = 60;
const NODE_ARCHIVE_MAX_PLAY_SECONDS = 10 * 60;
const ARCHIVE_SEEK_PREROLL_SECONDS = 12;
const ARCHIVE_LIVE_EDGE_FALLBACK_SECONDS = 180;

const cameraId = computed(() => String(route.params.id || ''));
const tokenlessLiveUrl = computed(() => camera.value?.stream_name ? `/cameras/${camera.value.stream_name}/live.m3u8` : '—');
const tokenlessArchiveUrl = computed(() => camera.value?.stream_name ? `/cameras/${camera.value.stream_name}/archive.m3u8` : '—');

function normalizeTimelineEventState(raw: unknown): boolean | null {
  if (typeof raw === 'boolean') return raw;
  if (typeof raw === 'number') {
    if (raw === 1) return true;
    if (raw === 0) return false;
    return null;
  }

  const value = String(raw ?? '').trim().toLowerCase();
  if (['true', '1', 'yes', 'on', 'active', 'motion', 'detected', 'start', 'started'].includes(value)) return true;
  if (['false', '0', 'no', 'off', 'inactive', 'clear', 'idle', 'none', 'end', 'ended'].includes(value)) return false;
  return null;
}

function normalizePlayerKitSdk(candidate: any) {
  if (!candidate) return null;
  if (typeof candidate.create === 'function') return candidate;
  if (typeof candidate.createNewDomofonPlayer === 'function') {
    return {
      ...candidate,
      create: candidate.createNewDomofonPlayer
    };
  }
  return null;
}

function currentPlayerKitSdk() {
  const win = window as PlayerKitWindow & Record<string, any>;
  const sdk = normalizePlayerKitSdk(win.NewDomofonPlayer) || normalizePlayerKitSdk((globalThis as Record<string, any>).NewDomofonPlayer);
  if (sdk) win.NewDomofonPlayer = sdk;
  return sdk;
}

function loadScript(src: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const existing = document.querySelector(`script[src="${src}"]`) as HTMLScriptElement | null;
    if (existing?.dataset.loaded === 'true') return resolve();
    if (existing) {
      existing.addEventListener('load', () => resolve(), { once: true });
      existing.addEventListener('error', () => reject(new Error(`Не удалось загрузить ${src}`)), { once: true });
      return;
    }

    const script = document.createElement('script');
    script.src = src;
    script.async = false;
    script.onload = () => {
      script.dataset.loaded = 'true';
      resolve();
    };
    script.onerror = () => reject(new Error(`Не удалось загрузить ${src}`));
    document.head.appendChild(script);
  });
}

async function waitForPlayerKitSdk(timeoutMs = 2500) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const sdk = currentPlayerKitSdk();
    if (sdk?.create) return sdk;
    await new Promise((resolve) => window.setTimeout(resolve, 50));
  }
  return currentPlayerKitSdk();
}

async function ensurePlayerKitAssets(): Promise<void> {
  if (currentPlayerKitSdk()?.create) return;
  if (assetsPromise) return assetsPromise;

  assetsPromise = (async () => {
    if (!document.querySelector(`link[href="${PLAYER_KIT_CSS}"]`)) {
      const link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = PLAYER_KIT_CSS;
      document.head.appendChild(link);
    }

    await loadScript(PLAYER_KIT_SCRIPT);
    await loadScript(PLAYER_KIT_SHIM);

    const sdk = await waitForPlayerKitSdk();
    if (!sdk?.create) {
      throw new Error('Player kit загружен, но глобальный SDK не найден. Проверьте player-kit и browser console.');
    }
  })();

  return assetsPromise;
}

function destroyPlayer() {
  archiveSeekGeneration += 1;
  archiveSeekAbortController?.abort();
  archiveSeekAbortController = null;
  archivePreparing.value = false;
  player?.destroy();
  player = null;
  if (playerRoot.value) playerRoot.value.innerHTML = '';
}

async function loadCamera() {
  const { data } = await api.get(`/cameras/${encodeURIComponent(cameraId.value)}`);
  camera.value = data.item;
}

async function loadStatus() {
  try {
    const { data } = await api.get(`/player/${encodeURIComponent(cameraId.value)}/status`);
    status.value = data;
  } catch (err: any) {
    status.value = { recording: false, error: err.response?.data?.error || err.message };
  }
}

async function createPlayer() {
  if (!playerRoot.value || !camera.value?.stream_name) return;
  await ensurePlayerKitAssets();

  const sdk = currentPlayerKitSdk();
  if (!sdk?.create) throw new Error('Player kit не зарегистрировался в window.NewDomofonPlayer');

  const id = cameraId.value;
  const streamName = camera.value.stream_name;
  const title = camera.value.name || streamName;

  const loadArchiveRanges = async (force = false) => {
    const end = new Date().toISOString();
    const start = new Date(Date.now() - Math.max(1, Number(camera.value?.retention_days || 1)) * 24 * 3600 * 1000).toISOString();
    const rangesKey = `${start.slice(0, 13)}|${end.slice(0, 13)}`;
    if (!force && latestArchiveRanges.length && latestArchiveRangesKey === rangesKey && Date.now() - latestArchiveRangesLoadedAt < 15_000) {
      return latestArchiveRanges;
    }
    const ranges = await api.get(`/player/${encodeURIComponent(id)}/archive/ranges`, {
      params: { start, end, source: 'node' }
    });
    latestArchiveRanges = (ranges.data.items || []).map((item: any) => ({
      startMs: new Date(item.start).getTime(),
      endMs: new Date(item.end).getTime()
    })).filter((item: any) => Number.isFinite(item.startMs) && Number.isFinite(item.endMs) && item.endMs > item.startMs);
    latestArchiveRangesLoadedAt = Date.now();
    latestArchiveRangesKey = rangesKey;
    return latestArchiveRanges;
  };

  const initialRanges = await loadArchiveRanges(true).catch(() => []);
  destroyPlayer();

  const nextPlayer = sdk.create({
    container: playerRoot.value,
    adapter: 'external',
    theme: 'auto',
    nativeControls: 'auto',
    maxDownloadDurationSec: 3600,
    onError: (err: unknown, context?: string) => {
      const candidate = err as { name?: string; code?: string } | null;
      if (candidate?.name === 'AbortError' || candidate?.name === 'CanceledError' || candidate?.code === 'ERR_CANCELED') return;
      error.value = `${context ? `${context}: ` : ''}${err instanceof Error ? err.message : String(err)}`;
    },
    external: {
      bootstrap: async () => {
        const live = await api.get(`/player/${encodeURIComponent(id)}/live`);

        return {
          streamName,
          title,
          live: {
            hlsUrl: live.data.liveHls || live.data.hls_url || live.data.playback_url
          },
          archive: {
            buildUrl: async (fromEpochSec: number, durationSec: number) => {
              const requestGeneration = ++archiveSeekGeneration;
              archiveSeekAbortController?.abort();
              const controller = new AbortController();
              archiveSeekAbortController = controller;
              archivePreparing.value = true;

              try {
                const nowMs = Date.now();
                const requestedWindowStartMs = fromEpochSec * 1000;
                const requestedWindowDurationMs = Math.max(1, Number(durationSec) || 1) * 1000;
                const rawRequestedSeekMs = requestedWindowStartMs + requestedWindowDurationMs / 2;
                if (rawRequestedSeekMs > nowMs + 60_000) {
                  throw new Error('Выбранное время ещё не записано в архив');
                }

                const requestedSeekMs = Math.min(rawRequestedSeekMs, nowMs - 1000);
                if (!latestArchiveRanges.length) {
                  await loadArchiveRanges(true).catch(() => []);
                }

                let targetSeekMs = requestedSeekMs;
                let matchingRange = latestArchiveRanges.find((range) => range.startMs <= targetSeekMs && range.endMs > targetSeekMs);

                if (latestArchiveRanges.length && !matchingRange) {
                  const nextRange = latestArchiveRanges.find((range) => range.startMs > targetSeekMs);
                  const previousRange = [...latestArchiveRanges].reverse().find((range) => range.endMs <= targetSeekMs);
                  const isLiveEdgeRequest = targetSeekMs >= nowMs - ARCHIVE_LIVE_EDGE_FALLBACK_SECONDS * 1000;

                  if (nextRange) {
                    matchingRange = nextRange;
                    targetSeekMs = nextRange.startMs;
                    error.value = 'В выбранной точке архива нет, открыт следующий доступный фрагмент';
                  } else if (isLiveEdgeRequest && previousRange) {
                    matchingRange = previousRange;
                    targetSeekMs = Math.max(previousRange.startMs, Math.min(targetSeekMs, previousRange.endMs - 1000));
                    error.value = '';
                  } else {
                    throw new Error('В выбранной точке архива нет');
                  }
                }

                const effectiveStartMs = matchingRange
                  ? Math.max(matchingRange.startMs, targetSeekMs - ARCHIVE_SEEK_PREROLL_SECONDS * 1000)
                  : Math.max(0, targetSeekMs - ARCHIVE_SEEK_PREROLL_SECONDS * 1000);

                const maxAvailableDuration = matchingRange
                  ? Math.max(1, Math.floor((matchingRange.endMs - effectiveStartMs) / 1000))
                  : Math.max(1, durationSec);
                const requestedDuration = Math.max(1, Math.min(Math.max(durationSec, NODE_ARCHIVE_MIN_PLAY_SECONDS), maxAvailableDuration, NODE_ARCHIVE_MAX_PLAY_SECONDS));
                const latestAllowedEndMs = Math.min(matchingRange?.endMs ?? nowMs - 1000, nowMs - 1000);
                const effectiveEndMs = Math.min(effectiveStartMs + requestedDuration * 1000, latestAllowedEndMs);

                if (effectiveEndMs <= effectiveStartMs) {
                  throw new Error('В выбранной точке ещё нет завершённого архивного фрагмента');
                }

                const archive = await api.get(`/player/${encodeURIComponent(id)}/archive`, {
                  params: {
                    start: new Date(effectiveStartMs).toISOString(),
                    end: new Date(effectiveEndMs).toISOString(),
                    source: 'node'
                  },
                  signal: controller.signal
                });

                if (requestGeneration !== archiveSeekGeneration) {
                  throw new DOMException('Archive seek superseded', 'AbortError');
                }

                return archive.data.archiveHls || archive.data.hls_url || archive.data.playback_url;
              } catch (err: any) {
                if (controller.signal.aborted || requestGeneration !== archiveSeekGeneration || err?.code === 'ERR_CANCELED') {
                  throw new DOMException('Archive seek superseded', 'AbortError');
                }
                throw err;
              } finally {
                if (requestGeneration === archiveSeekGeneration) {
                  archiveSeekAbortController = null;
                  archivePreparing.value = false;
                }
              }
            },
            ranges: initialRanges,
            loadRanges: async (_signal?: AbortSignal) => loadArchiveRanges()
          },
          events: {
            load: async (fromMs: number, toMs: number, _signal?: AbortSignal) => {
              const events = await api.get(`/cameras/${encodeURIComponent(id)}/events`, {
                params: { start: new Date(fromMs).toISOString(), end: new Date(toMs).toISOString() }
              });
              return (events.data.items || []).map((event: any) => {
                const occurredAtMs = new Date(event.occurred_at || event.occurredAt || event.time || event.timestamp).getTime();
                const state = normalizeTimelineEventState(event.IsMotion ?? event.is_motion ?? event.state ?? event.event_state ?? event.motion_state);
                return {
                  id: event.id,
                  occurredAtMs,
                  timeMs: occurredAtMs,
                  type: event.event_type || event.type || event.topic || 'event',
                  title: event.title || event.event_type || event.type || 'Событие',
                  state,
                  data: event.data || event.raw || event,
                  raw: event
                };
              }).filter((event: any) => Number.isFinite(event.occurredAtMs));
            }
          },
          download: {
            start: async (fromMs: number, toMs: number) => {
              const start = new Date(fromMs).toISOString();
              const end = new Date(toMs).toISOString();
              const result = await api.get(`/player/${encodeURIComponent(id)}/export`, {
                params: { start, end, source: 'node' }
              });
              const url = result.data.exportMp4 || result.data.url;
              if (url) window.open(url, '_blank', 'noopener,noreferrer');
            }
          },
          capabilities: {
            live: true,
            archive: true,
            events: true,
            archiveGaps: true,
            snapshot: false,
            download: true,
            audio: true,
            speedControl: true,
            dateRangePicker: true
          }
        };
      }
    }
  });

  player = nextPlayer;
  await nextPlayer.mount();
}

async function reloadPlayer() {
  if (!cameraId.value) return;
  loading.value = true;
  error.value = '';
  latestArchiveRanges = [];
  latestArchiveRangesLoadedAt = 0;
  latestArchiveRangesKey = '';

  try {
    destroyPlayer();
    await loadCamera();
    await nextTick();
    await createPlayer();
    await loadStatus();
  } catch (err: any) {
    error.value = err.response?.data?.error || err.message || 'Не удалось запустить плеер';
  } finally {
    loading.value = false;
  }
}

watch(cameraId, () => {
  void reloadPlayer();
});

onMounted(() => {
  void reloadPlayer();
});

onBeforeUnmount(() => {
  destroyPlayer();
});
</script>

<style scoped>
.player-page {
  min-height: calc(100vh - 64px);
}

.player-card {
  position: relative;
  min-height: 660px;
  background: #05070b;
}

.player-kit-host {
  min-height: 660px;
  height: calc(100vh - 180px);
  background: #05070b;
}

.player-loading {
  min-height: 420px;
  display: grid;
  place-items: center;
  color: #f8fafc;
}

.archive-preparing {
  position: absolute;
  inset: 0;
  z-index: 10;
  display: grid;
  place-content: center;
  gap: 12px;
  color: #f8fafc;
  background: rgba(5, 7, 11, 0.54);
  text-align: center;
  pointer-events: all;
}

.status-json {
  max-height: 280px;
  overflow: auto;
  white-space: pre-wrap;
  font-size: 12px;
}

code {
  word-break: break-all;
}
</style>
