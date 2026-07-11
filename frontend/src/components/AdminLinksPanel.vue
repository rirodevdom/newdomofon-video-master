<template>
  <div>
    <v-alert v-if="message" :type="messageType" variant="tonal" class="mb-4" closable @click:close="message = ''">
      {{ message }}
    </v-alert>

    <div class="d-flex align-center flex-wrap ga-3 mb-4">
      <v-text-field
        v-model="search"
        density="compact"
        label="Поиск камеры"
        prepend-inner-icon="mdi-magnify"
        hide-details
        style="max-width: 340px"
      />
      <v-spacer />
      <v-btn variant="tonal" prepend-icon="mdi-refresh" :loading="loading" @click="load">
        Обновить
      </v-btn>
    </div>

    <v-alert type="info" variant="tonal" class="mb-4">
      Нажмите на камеру, затем выберите один из уже привязанных токенов или добавьте новый. Ссылки формируются для конкретной пары «камера + токен». HLS, MPEG-TS, DASH и JPEG работают через HTTPS gateway. RTSP показывается только когда на сервере настроен публичный RTSP gateway.
    </v-alert>

    <v-skeleton-loader v-if="loading && !cameras.length" type="table-row@5" />

    <v-expansion-panels v-else multiple variant="accordion">
      <v-expansion-panel v-for="camera in filteredCameras" :key="camera.id" :value="camera.id">
        <v-expansion-panel-title>
          <div class="d-flex align-center flex-wrap ga-3 w-100 pr-4">
            <div>
              <div class="font-weight-medium">{{ camera.name }}</div>
              <div class="text-caption text-medium-emphasis"><code>{{ camera.stream_name }}</code></div>
            </div>
            <v-chip size="small" variant="tonal" prepend-icon="mdi-server-network">
              {{ camera.node_name || 'Node не назначена' }}
            </v-chip>
            <v-chip size="small" :color="camera.managed_tokens.length ? 'primary' : 'warning'" variant="tonal">
              Токенов: {{ camera.managed_tokens.length }}
            </v-chip>
          </div>
        </v-expansion-panel-title>

        <v-expansion-panel-text>
          <v-row>
            <v-col cols="12" lg="7">
              <v-card variant="outlined" class="pa-4 h-100">
                <div class="text-subtitle-1 font-weight-medium mb-3">Привязанные токены</div>

                <v-list v-if="camera.managed_tokens.length" density="compact" class="pa-0">
                  <v-list-item v-for="token in camera.managed_tokens" :key="token.id" class="px-0">
                    <template #prepend>
                      <v-icon :color="isTokenUsable(token) ? 'success' : 'warning'">
                        {{ isTokenUsable(token) ? 'mdi-key-variant' : 'mdi-key-alert' }}
                      </v-icon>
                    </template>
                    <v-list-item-title>{{ token.name }}</v-list-item-title>
                    <v-list-item-subtitle>
                      {{ tokenStatusText(token) }} · {{ token.expires_at ? `до ${formatDate(token.expires_at)}` : 'без срока' }}
                    </v-list-item-subtitle>
                    <template #append>
                      <v-btn
                        size="small"
                        color="primary"
                        variant="tonal"
                        class="mr-2"
                        :disabled="!isTokenUsable(token)"
                        :loading="openingKey === `${camera.id}:${token.id}`"
                        @click="openLinks(camera, token.id)"
                      >
                        Показать ссылки
                      </v-btn>
                      <v-btn
                        size="small"
                        color="error"
                        variant="text"
                        icon="mdi-link-off"
                        title="Отвязать токен"
                        @click="detach(camera, token)"
                      />
                    </template>
                  </v-list-item>
                </v-list>

                <div v-else class="text-medium-emphasis mb-4">К камере ещё не привязан ни один токен.</div>

                <v-divider class="my-4" />

                <div class="text-subtitle-2 mb-2">Добавить токен</div>
                <div class="d-flex align-center flex-wrap ga-2">
                  <v-select
                    v-model="selection[camera.id]"
                    :items="availableTokenOptions(camera)"
                    item-title="option_title"
                    item-value="id"
                    density="compact"
                    hide-details
                    clearable
                    label="Управляемый токен"
                    style="min-width: 280px; flex: 1"
                  >
                    <template #item="{ props, item }">
                      <v-list-item v-bind="props" :subtitle="tokenOptionSubtitle(item.raw)" />
                    </template>
                  </v-select>
                  <v-btn
                    color="primary"
                    variant="tonal"
                    :disabled="!selection[camera.id]"
                    :loading="openingKey === `${camera.id}:${selection[camera.id]}`"
                    @click="openLinks(camera, selection[camera.id])"
                  >
                    Привязать и показать
                  </v-btn>
                </div>
              </v-card>
            </v-col>

            <v-col cols="12" lg="5">
              <v-card variant="outlined" class="pa-4 h-100">
                <div class="text-subtitle-1 font-weight-medium mb-2">Общая ссылка</div>
                <template v-if="generated[camera.id]">
                  <div class="text-caption text-medium-emphasis mb-2">
                    Токен: <strong>{{ generated[camera.id].managed_token?.name }}</strong>
                  </div>
                  <v-textarea
                    :model-value="generated[camera.id].smartyard_url"
                    label="SmartYard / общий player URL"
                    rows="3"
                    readonly
                    density="compact"
                  />
                  <v-btn size="small" variant="tonal" prepend-icon="mdi-content-copy" @click="copyText(generated[camera.id].smartyard_url)">
                    Копировать
                  </v-btn>
                </template>
                <div v-else class="text-medium-emphasis">
                  Выберите токен и нажмите «Показать ссылки».
                </div>
              </v-card>
            </v-col>
          </v-row>

          <v-card v-if="generated[camera.id]" variant="outlined" class="mt-4">
            <v-card-title>Рабочие ссылки: {{ generated[camera.id].managed_token?.name }}</v-card-title>
            <v-card-subtitle>
              Ссылки используют один управляемый токен. Его отключение, удаление или ротация сразу изменит доступ.
            </v-card-subtitle>

            <v-table>
              <thead>
                <tr>
                  <th>Тип</th>
                  <th>Протокол</th>
                  <th>Состояние</th>
                  <th>Content-Type</th>
                  <th style="min-width: 420px">URL</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="link in generated[camera.id].format_links || []" :key="link.type">
                  <td><v-chip size="small" color="primary" variant="tonal">{{ link.type }}</v-chip></td>
                  <td>{{ link.protocol }}</td>
                  <td>
                    <v-chip size="small" :color="link.available ? 'success' : 'warning'" variant="tonal">
                      {{ link.available ? 'доступна' : 'не настроена' }}
                    </v-chip>
                  </td>
                  <td><code>{{ link.content_type || '—' }}</code></td>
                  <td>
                    <v-text-field
                      v-if="link.url"
                      :model-value="link.url"
                      density="compact"
                      hide-details
                      readonly
                    />
                    <span v-else class="text-caption text-medium-emphasis">{{ link.note || 'Ссылка недоступна' }}</span>
                  </td>
                  <td class="text-right" style="white-space: nowrap">
                    <v-btn
                      size="small"
                      variant="text"
                      icon="mdi-content-copy"
                      title="Копировать"
                      :disabled="!link.url"
                      @click="copyText(link.url)"
                    />
                    <v-btn
                      v-if="link.type === 'JPEG' && link.url"
                      size="small"
                      variant="text"
                      icon="mdi-image-outline"
                      title="Открыть JPEG"
                      :href="link.url"
                      target="_blank"
                    />
                  </td>
                </tr>
              </tbody>
            </v-table>

            <v-card-text>
              <v-alert v-if="generated[camera.id].format_links?.some((item: any) => item.type === 'RTSP' && !item.available)" type="warning" variant="tonal" density="compact">
                Для RTSP задайте на master переменную <code>RTSP_PUBLIC_URL_TEMPLATE</code>, например
                <code>rtsp://media.example.com:8554/{stream}?token={token}</code>, и настройте соответствующий RTSP gateway.
              </v-alert>
            </v-card-text>
          </v-card>
        </v-expansion-panel-text>
      </v-expansion-panel>
    </v-expansion-panels>

    <v-alert v-if="!loading && !filteredCameras.length" type="info" variant="tonal">
      Камеры не найдены.
    </v-alert>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import { api } from '../api';

const cameras = ref<any[]>([]);
const managedTokens = ref<any[]>([]);
const generated = ref<Record<string, any>>({});
const selection = reactive<Record<string, string | null>>({});
const search = ref('');
const loading = ref(false);
const openingKey = ref<string | null>(null);
const message = ref('');
const messageType = ref<'success' | 'error'>('success');

const filteredCameras = computed(() => {
  const needle = search.value.trim().toLowerCase();
  if (!needle) return cameras.value;
  return cameras.value.filter((camera) => [camera.name, camera.stream_name, camera.node_name]
    .some((value) => String(value || '').toLowerCase().includes(needle)));
});

function notify(text: string, type: 'success' | 'error' = 'success') {
  message.value = text;
  messageType.value = type;
}

function formatDate(value: string | null | undefined) {
  return value ? new Date(value).toLocaleString() : '—';
}

function tokenStatusText(token: any) {
  if (!token?.is_active) return 'отключён';
  if (token.expires_at && new Date(token.expires_at).getTime() <= Date.now()) return 'истёк';
  if (!token.scopes?.includes('camera')) return 'нет права на видео';
  return 'активен';
}

function isTokenUsable(token: any) {
  return tokenStatusText(token) === 'активен';
}

function tokenOptionSubtitle(token: any) {
  const expiry = token.expires_at ? `до ${formatDate(token.expires_at)}` : 'без срока';
  return `${tokenStatusText(token)} · ${expiry}`;
}

function availableTokenOptions(camera: any) {
  const attached = new Set((camera.managed_tokens || []).map((item: any) => item.id));
  return managedTokens.value
    .filter((token) => token.scopes?.includes('camera') && !attached.has(token.id))
    .map((token) => ({
      ...token,
      option_title: isTokenUsable(token) ? token.name : `${token.name} (${tokenStatusText(token)})`
    }));
}

async function copyText(value: string | null | undefined) {
  if (!value) return;
  await navigator.clipboard?.writeText(value);
  notify('Ссылка скопирована');
}

async function load() {
  loading.value = true;
  try {
    const [systemResponse, managedResponse] = await Promise.all([
      api.get('/tokens'),
      api.get('/tokens/managed-camera-tokens')
    ]);

    const tokens = managedResponse.data.items || [];
    const assignments = new Map<string, any[]>();
    for (const token of tokens) {
      for (const camera of token.assigned_cameras || []) {
        const list = assignments.get(camera.id) || [];
        list.push(token);
        assignments.set(camera.id, list);
      }
    }

    managedTokens.value = tokens;
    cameras.value = (systemResponse.data.camera_links || []).map((camera: any) => ({
      ...camera,
      managed_tokens: assignments.get(camera.id) || []
    }));

    const cameraIds = new Set(cameras.value.map((camera) => camera.id));
    for (const id of Object.keys(selection)) {
      if (!cameraIds.has(id)) delete selection[id];
    }
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Не удалось загрузить ссылки', 'error');
  } finally {
    loading.value = false;
  }
}

async function openLinks(camera: any, tokenId: string | null | undefined) {
  if (!tokenId) return notify('Выберите токен', 'error');
  openingKey.value = `${camera.id}:${tokenId}`;
  try {
    const response = await api.post(`/tokens/camera-links/${camera.id}`, { managed_token_id: tokenId });
    generated.value = { ...generated.value, [camera.id]: response.data };
    selection[camera.id] = null;
    notify(response.data.assignment_added ? 'Токен привязан, ссылки сформированы' : 'Ссылки сформированы');
    await load();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Не удалось сформировать ссылки', 'error');
  } finally {
    openingKey.value = null;
  }
}

async function detach(camera: any, token: any) {
  if (!confirm(`Отвязать токен «${token.name}» от камеры «${camera.name}»?`)) return;
  try {
    await api.delete(`/tokens/managed-camera-tokens/${token.id}/cameras/${camera.id}`);
    if (generated.value[camera.id]?.managed_token?.id === token.id) {
      const next = { ...generated.value };
      delete next[camera.id];
      generated.value = next;
    }
    notify('Токен отвязан');
    await load();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Не удалось отвязать токен', 'error');
  }
}

onMounted(load);
</script>
