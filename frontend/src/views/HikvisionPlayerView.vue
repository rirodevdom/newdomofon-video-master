<template>
  <v-container fluid class="pa-6 player-page">
    <div class="d-flex align-center mb-4 flex-wrap ga-2">
      <div>
        <h1 class="text-h4">{{ channel?.name || 'Hikvision-канал' }}</h1>
        <div class="text-medium-emphasis">
          Канал {{ channel?.physical_channel || '—' }} · поток {{ channel?.stream_name || '—' }}
          <span v-if="channel?.dvr_server_name"> · {{ channel.dvr_server_name }}</span>
        </div>
      </div>
      <v-spacer />
      <v-btn prepend-icon="mdi-refresh" :loading="loading" @click="reloadPlayer">Обновить</v-btn>
      <v-btn variant="tonal" to="/devices">К устройствам</v-btn>
    </div>

    <v-alert v-if="error" type="error" variant="tonal" class="mb-4" closable @click:close="error = ''">
      {{ error }}
    </v-alert>

    <v-row>
      <v-col cols="12" lg="9">
        <v-card class="player-card">
          <div ref="playerRoot" class="player-kit-host">
            <div v-if="loading" class="player-loading">Загрузка Hikvision-плеера...</div>
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
            <v-chip :color="status?.recording ? 'success' : status?.online === false ? 'error' : 'warning'">
              {{ status?.recording ? 'online' : status?.online === false ? 'offline' : 'unknown' }}
            </v-chip>
            <pre class="mt-4 status-json">{{ status }}</pre>
          </v-card-text>
        </v-card>

        <v-card>
          <v-card-title>Технические данные</v-card-title>
          <v-card-text>
            <div class="mb-2"><strong>Устройство:</strong> {{ channel?.device_name || '—' }}</div>
            <div class="mb-2"><strong>Node:</strong> {{ channel?.dvr_server_name || '—' }}</div>
            <div class="mb-2"><strong>Основной поток:</strong> {{ channel?.stream_name || '—' }}</div>
            <div class="mb-2"><strong>Профилей:</strong> {{ Array.isArray(channel?.streams) ? channel.streams.length : 0 }}</div>
            <div class="mb-2"><strong>Архив:</strong> {{ channel?.retention_days || '—' }} дней</div>
            <div><strong>Хранение:</strong> {{ channel?.archive_storage === 'device' ? 'Hikvision/NVR' : 'Hikvision-node' }}</div>
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
const ARCHIVE_MAX_SECONDS = 10 * 60;
const ARCHIVE_MIN_SECONDS = 60;

const route = useRoute();
const channel = ref<any>(null);
const status = ref<any>(null);
const error = ref('');
const loading = ref(false);
const archivePreparing = ref(false);
const playerRoot = ref<HTMLElement | null>(null);
let player: PlayerKitInstance | null = null;
let assetsPromise: Promise<void> | null = null;
let latestRanges: Array<{ startMs: number; endMs: number }> = [];

const channelId = computed(() => String(route.params.id || ''));
const apiBase = computed(() => `/hikvision-player/${encodeURIComponent(channelId.value)}`);

function normalizePlayerKitSdk(candidate: any) {
  if (!candidate) return null;
  if (typeof candidate.create === 'function') return candidate;
  if (typeof candidate.createNewDomofonPlayer === 'function') {
    return { ...candidate, create: candidate.createNewDomofonPlayer };
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
    const started = Date.now();
    while (!currentPlayerKitSdk()?.create && Date.now() - started < 3000) {
      await new Promise((resolve) => window.setTimeout(resolve, 50));
    }
    if (!currentPlayerKitSdk()?.create) throw new Error('Player kit загружен, но SDK не найден');
  })();
  return assetsPromise;
}

function destroyPlayer() {
  player?.destroy();
  player = null;
  archivePreparing.value = false;
  if (playerRoot.value) playerRoot.value.innerHTML = '';
}

async function loadChannel() {
  const { data } = await api.get(apiBase.value);
  channel.value = data.item;
}

async function loadStatus() {
  try {
    const { data } = await api.get(`${apiBase.value}/status`);
    status.value = data;
  } catch (err: any) {
    status.value = { recording: false, error: err.response?.data?.error || err.message };
  }
}

async function loadArchiveRanges() {
  const end = new Date().toISOString();
  const days = Math.max(1, Number(channel.value?.retention_days || 1));
  const start = new Date(Date.now() - days * 24 * 3600 * 1000).toISOString();
  const { data } = await api.get(`${apiBase.value}/archive/ranges`, { params: { start, end } });
  latestRanges = (data.items || []).map((item: any) => ({
    startMs: new Date(item.start).getTime(),
    endMs: new Date(item.end).getTime()
  })).filter((item: any) => Number.isFinite(item.startMs) && Number.isFinite(item.endMs) && item.endMs > item.startMs);
  return latestRanges;
}

async function createPlayer() {
  if (!playerRoot.value || !channel.value) return;
  await ensurePlayerKitAssets();
  const sdk = currentPlayerKitSdk();
  if (!sdk?.create) throw new Error('Player kit не зарегистрировался');

  const initialRanges = await loadArchiveRanges().catch(() => []);
  destroyPlayer();

  const nextPlayer = sdk.create({
    container: playerRoot.value,
    adapter: 'external',
    theme: 'auto',
    nativeControls: 'auto',
    maxDownloadDurationSec: 3600,
    onError: (err: unknown, context?: string) => {
      error.value = `${context ? `${context}: ` : ''}${err instanceof Error ? err.message : String(err)}`;
    },
    external: {
      bootstrap: async () => {
        const live = await api.get(`${apiBase.value}/live`);
        return {
          streamName: channel.value.stream_name || channel.value.id,
          title: channel.value.name || channel.value.id,
          live: { hlsUrl: live.data.liveHls || live.data.hls_url || live.data.playback_url },
          archive: {
            buildUrl: async (fromEpochSec: number, durationSec: number) => {
              archivePreparing.value = true;
              try {
                const requestedMs = fromEpochSec * 1000 + Math.max(1, durationSec) * 500;
                let range = latestRanges.find((item) => item.startMs <= requestedMs && item.endMs > requestedMs);
                if (!range) {
                  range = latestRanges.find((item) => item.startMs > requestedMs)
                    || [...latestRanges].reverse().find((item) => item.endMs <= requestedMs);
                }
                if (!range) throw new Error('В выбранном периоде архив не найден');
                const startMs = Math.max(range.startMs, Math.min(requestedMs, range.endMs - 1000) - 10_000);
                const seconds = Math.max(1, Math.min(Math.max(durationSec, ARCHIVE_MIN_SECONDS), ARCHIVE_MAX_SECONDS));
                const endMs = Math.min(range.endMs, startMs + seconds * 1000, Date.now() - 1000);
                if (endMs <= startMs) throw new Error('Архивный фрагмент ещё не завершён');
                const archive = await api.get(`${apiBase.value}/archive`, {
                  params: { start: new Date(startMs).toISOString(), end: new Date(endMs).toISOString() }
                });
                return archive.data.archiveHls || archive.data.hls_url || archive.data.playback_url;
              } finally {
                archivePreparing.value = false;
              }
            },
            ranges: initialRanges,
            loadRanges: async () => loadArchiveRanges()
          },
          events: { load: async () => [] },
          download: {
            start: async (fromMs: number, toMs: number) => {
              const result = await api.get(`${apiBase.value}/export`, {
                params: { start: new Date(fromMs).toISOString(), end: new Date(toMs).toISOString() }
              });
              const url = result.data.exportMp4 || result.data.url;
              if (url) window.open(url, '_blank', 'noopener,noreferrer');
            }
          },
          capabilities: {
            live: true,
            archive: true,
            events: false,
            archiveGaps: true,
            snapshot: true,
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
  if (!channelId.value) return;
  loading.value = true;
  error.value = '';
  latestRanges = [];
  try {
    destroyPlayer();
    await loadChannel();
    await nextTick();
    await createPlayer();
    await loadStatus();
  } catch (err: any) {
    error.value = err.response?.data?.error || err.message || 'Не удалось запустить Hikvision-плеер';
  } finally {
    loading.value = false;
  }
}

watch(channelId, () => { void reloadPlayer(); });
onMounted(() => { void reloadPlayer(); });
onBeforeUnmount(() => { destroyPlayer(); });
</script>

<style scoped>
.player-page { min-height: calc(100vh - 64px); }
.player-card { position: relative; min-height: 660px; background: #05070b; }
.player-kit-host { min-height: 660px; height: calc(100vh - 180px); background: #05070b; }
.player-loading { min-height: 420px; display: grid; place-items: center; color: #f8fafc; }
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
}
.status-json { max-height: 280px; overflow: auto; white-space: pre-wrap; font-size: 12px; }
</style>
