<script setup lang="ts">
import axios from "axios";
import { computed, ref, watch } from "vue";
import type { Camera, FormatedRange } from "@/types/camera";

interface CameraMotionEvent {
  id: string;
  camera_id: string;
  stream_name: string;
  event_type: string;
  event_state: string | null;
  occurred_at: string;
  timestamp: number;
  topic?: string | null;
  source_name?: string | null;
}

const props = defineProps<{
  camera: Camera;
  range?: FormatedRange;
}>();

const emit = defineEmits<{
  select: [timestamp: number];
}>();

const events = ref<CameraMotionEvent[]>([]);
const loading = ref(false);
const error = ref("");

const visibleEvents = computed(() =>
  events.value
    .slice()
    .sort((a, b) => b.timestamp - a.timestamp)
    .slice(0, 200)
);

function rangeWindow() {
  if (props.range) {
    return {
      from: props.range.from,
      to: props.range.from + props.range.duration,
    };
  }

  const to = Math.floor(Date.now() / 1000);
  return { from: to - 24 * 60 * 60, to };
}

function formatTime(timestamp: number) {
  return new Intl.DateTimeFormat(undefined, {
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(timestamp));
}

function eventLabel(event: CameraMotionEvent) {
  if (event.event_type === "motion") return "Движение";
  if (event.event_type === "line_crossing") return "Пересечение линии";
  if (event.event_type === "intrusion") return "Вторжение";
  if (event.event_type === "tamper") return "Саботаж камеры";
  return event.event_type || "Событие";
}

async function loadEvents() {
  loading.value = true;
  error.value = "";

  try {
    const base = String(props.camera.url || "").replace(/\/+$/, "");
    const window = rangeWindow();
    const response = await axios.get(`${base}/events.json`, {
      params: {
        token: props.camera.token,
        from: window.from,
        to: window.to,
        limit: 2000,
      },
      timeout: 15000,
    });

    events.value = Array.isArray(response.data?.items)
      ? response.data.items
      : Array.isArray(response.data?.events)
        ? response.data.events
        : [];
  } catch (requestError: any) {
    events.value = [];
    error.value = requestError?.response?.data?.error || requestError?.message || "Не удалось загрузить события";
  } finally {
    loading.value = false;
  }
}

watch(
  () => [props.camera.url, props.camera.token, props.range?.from, props.range?.duration],
  loadEvents,
  { immediate: true }
);
</script>

<template>
  <section class="camera-events">
    <header class="camera-events__header">
      <strong>События камеры</strong>
      <button type="button" class="camera-events__refresh" @click="loadEvents" :disabled="loading">
        {{ loading ? "…" : "↻" }}
      </button>
    </header>

    <p v-if="error" class="camera-events__message camera-events__message--error">{{ error }}</p>
    <p v-else-if="loading && !visibleEvents.length" class="camera-events__message">Загрузка…</p>
    <p v-else-if="!visibleEvents.length" class="camera-events__message">За выбранный период событий нет</p>

    <div v-else class="camera-events__list">
      <button
        v-for="event in visibleEvents"
        :key="event.id"
        type="button"
        class="camera-events__item"
        @click="emit('select', event.timestamp)"
      >
        <span>{{ eventLabel(event) }}</span>
        <time>{{ formatTime(event.timestamp) }}</time>
      </button>
    </div>
  </section>
</template>

<style scoped lang="scss">
.camera-events {
  width: 320px;
  margin-top: 16px;
  border-top: 1px solid #d8dce2;
  padding-top: 12px;

  &__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 8px;
  }

  &__refresh {
    width: 32px;
    height: 32px;
    border: 1px solid #d8dce2;
    border-radius: 8px;
    background: var(--color-background);
    color: inherit;
    cursor: pointer;
  }

  &__message {
    margin: 8px 0;
    font-size: 13px;
    opacity: 0.75;

    &--error {
      color: #ff3b30;
      opacity: 1;
    }
  }

  &__list {
    display: flex;
    flex-direction: column;
    gap: 6px;
    max-height: 300px;
    overflow: auto;
  }

  &__item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    width: 100%;
    padding: 8px 10px;
    border: 1px solid #e4e7eb;
    border-radius: 8px;
    background: var(--color-background);
    color: inherit;
    text-align: left;
    cursor: pointer;

    &:hover {
      border-color: #298bff;
    }

    time {
      white-space: nowrap;
      font-size: 12px;
      opacity: 0.75;
    }
  }
}
</style>
