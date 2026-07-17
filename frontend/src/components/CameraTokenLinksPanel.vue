<template>
  <v-card class="mt-4">
    <v-card-title class="d-flex align-center flex-wrap ga-2">
      <span>Ссылки доступа по токенам</span>
      <v-spacer />
      <v-btn size="small" variant="tonal" prepend-icon="mdi-refresh" :loading="loading" @click="load">
        Обновить
      </v-btn>
    </v-card-title>
    <v-card-subtitle>
      Здесь показаны рабочие ссылки для каждого токена, уже привязанного к камере. Управление привязками выполняется в разделе «Камеры».
    </v-card-subtitle>

    <v-card-text>
      <v-alert v-if="message" :type="messageType" variant="tonal" class="mb-4" closable @click:close="message = ''">
        {{ message }}
      </v-alert>

      <v-skeleton-loader v-if="loading && !assignedTokens.length" type="article, table" />

      <v-alert v-else-if="!assignedTokens.length" type="info" variant="tonal">
        К камере не привязан ни один управляемый токен.
      </v-alert>

      <v-expansion-panels v-else multiple variant="accordion">
        <v-expansion-panel v-for="token in assignedTokens" :key="token.id" :value="token.id">
          <v-expansion-panel-title>
            <div class="d-flex align-center flex-wrap ga-2 w-100 pr-4">
              <strong>{{ token.name }}</strong>
              <v-chip v-if="isSystemToken(token)" size="x-small" variant="tonal">Системный fallback</v-chip>
              <v-chip v-if="token.auto_assign_new_cameras" size="x-small" color="primary" variant="tonal">Всем камерам</v-chip>
              <v-chip size="x-small" :color="isTokenUsable(token) ? 'success' : 'warning'" variant="tonal">
                {{ tokenStatusText(token) }}
              </v-chip>
            </div>
          </v-expansion-panel-title>

          <v-expansion-panel-text>
            <v-alert v-if="errors[token.id]" type="error" variant="tonal" density="compact" class="mb-4">
              {{ errors[token.id] }}
            </v-alert>

            <div v-if="loadingTokenId === token.id" class="d-flex align-center ga-3 py-6">
              <v-progress-circular indeterminate color="primary" size="24" />
              <span>Формируем ссылки...</span>
            </div>

            <template v-else-if="generated[token.id]">
              <v-row>
                <v-col cols="12">
                  <v-textarea
                    :model-value="generated[token.id].smartyard_url"
                    label="Общая ссылка на player"
                    rows="2"
                    readonly
                    density="compact"
                  />
                  <v-btn size="small" variant="tonal" prepend-icon="mdi-content-copy" @click="copyText(generated[token.id].smartyard_url)">
                    Копировать общую ссылку
                  </v-btn>
                </v-col>
              </v-row>

              <v-table class="mt-4">
                <thead>
                  <tr>
                    <th>Тип</th>
                    <th>Протокол</th>
                    <th>Состояние</th>
                    <th style="min-width: 420px">URL</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr v-for="link in generated[token.id].format_links || []" :key="link.type">
                    <td><v-chip size="small" color="primary" variant="tonal">{{ link.type }}</v-chip></td>
                    <td>{{ link.protocol }}</td>
                    <td>
                      <v-chip size="small" :color="link.available ? 'success' : 'warning'" variant="tonal">
                        {{ link.available ? 'доступна' : 'не настроена' }}
                      </v-chip>
                    </td>
                    <td>
                      <v-text-field v-if="link.url" :model-value="link.url" density="compact" hide-details readonly />
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

              <v-row class="mt-3">
                <v-col cols="12" lg="6">
                  <v-textarea
                    :model-value="generated[token.id].archive_url_template"
                    label="Шаблон ссылки архива"
                    rows="3"
                    readonly
                    density="compact"
                  />
                  <v-btn size="small" variant="tonal" prepend-icon="mdi-content-copy" @click="copyText(generated[token.id].archive_url_template)">
                    Копировать шаблон архива
                  </v-btn>
                </v-col>
                <v-col cols="12" lg="6">
                  <v-textarea
                    :model-value="generated[token.id].events_url_template"
                    label="Шаблон ссылки событий"
                    rows="3"
                    readonly
                    density="compact"
                  />
                  <v-btn size="small" variant="tonal" prepend-icon="mdi-content-copy" @click="copyText(generated[token.id].events_url_template)">
                    Копировать шаблон событий
                  </v-btn>
                </v-col>
              </v-row>
            </template>

            <div v-else class="d-flex align-center ga-2 py-2">
              <span class="text-medium-emphasis">Ссылки ещё не сформированы.</span>
              <v-btn
                size="small"
                color="primary"
                variant="tonal"
                :disabled="!isTokenUsable(token)"
                @click="generateLinks(token)"
              >
                Сформировать
              </v-btn>
            </div>
          </v-expansion-panel-text>
        </v-expansion-panel>
      </v-expansion-panels>
    </v-card-text>
  </v-card>
</template>

<script setup lang="ts">
import { onMounted, ref, watch } from 'vue';
import { api } from '../api';

const SYSTEM_MANAGED_TOKEN_ID = '00000000-0000-4000-8000-000000000001';
const props = defineProps<{ cameraId: string }>();

const assignedTokens = ref<any[]>([]);
const generated = ref<Record<string, any>>({});
const errors = ref<Record<string, string>>({});
const loading = ref(false);
const loadingTokenId = ref<string | null>(null);
const message = ref('');
const messageType = ref<'success' | 'error'>('success');

function isSystemToken(token: any) {
  return token?.id === SYSTEM_MANAGED_TOKEN_ID;
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

async function copyText(value: string | null | undefined) {
  if (!value) return;
  await navigator.clipboard?.writeText(value);
  message.value = 'Ссылка скопирована';
  messageType.value = 'success';
}

async function generateLinks(token: any) {
  if (!isTokenUsable(token)) return;
  loadingTokenId.value = token.id;
  errors.value = { ...errors.value, [token.id]: '' };
  try {
    const response = await api.post(`/tokens/camera-links/${props.cameraId}`, { managed_token_id: token.id });
    generated.value = { ...generated.value, [token.id]: response.data };
  } catch (err: any) {
    errors.value = {
      ...errors.value,
      [token.id]: err.response?.data?.error || err.message || 'Не удалось сформировать ссылки'
    };
  } finally {
    loadingTokenId.value = null;
  }
}

async function load() {
  loading.value = true;
  message.value = '';
  try {
    const response = await api.get('/tokens/managed-camera-tokens');
    assignedTokens.value = (response.data.items || [])
      .filter((token: any) => (token.assigned_cameras || []).some((camera: any) => camera.id === props.cameraId))
      .sort((left: any, right: any) => {
        if (isSystemToken(left) !== isSystemToken(right)) return isSystemToken(left) ? 1 : -1;
        return String(left.name || '').localeCompare(String(right.name || ''), 'ru');
      });

    const activeIds = new Set(assignedTokens.value.map((token: any) => token.id));
    generated.value = Object.fromEntries(Object.entries(generated.value).filter(([id]) => activeIds.has(id)));
    errors.value = Object.fromEntries(Object.entries(errors.value).filter(([id]) => activeIds.has(id)));

    for (const token of assignedTokens.value) {
      if (isTokenUsable(token) && !generated.value[token.id]) {
        await generateLinks(token);
      }
    }
  } catch (err: any) {
    message.value = err.response?.data?.error || err.message || 'Не удалось загрузить токены камеры';
    messageType.value = 'error';
  } finally {
    loading.value = false;
  }
}

watch(() => props.cameraId, () => {
  generated.value = {};
  errors.value = {};
  void load();
});

onMounted(load);
</script>
