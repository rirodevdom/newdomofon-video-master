<template>
  <v-container fluid class="pa-6">
    <div class="d-flex align-center mb-4 flex-wrap ga-2">
      <h1 class="text-h4">Камеры</h1>
      <v-spacer />
      <v-text-field v-model="search" density="compact" label="Поиск" hide-details style="max-width: 280px" />
      <v-btn v-if="auth.isAdmin" color="primary" prepend-icon="mdi-devices" to="/devices">
        Настроить через устройства
      </v-btn>
    </div>

    <v-alert type="info" variant="tonal" class="mb-4">
      Параметры потока, устройство, video node, место хранения архива и срок хранения настраиваются внутри раздела «Устройства».
      Привязки управляемых токенов настраиваются здесь, а готовые ссылки доступны на странице просмотра камеры.
    </v-alert>

    <v-alert v-if="message" :type="messageType" variant="tonal" class="mb-4" closable @click:close="message = ''">
      {{ message }}
    </v-alert>

    <v-card>
      <v-table>
        <thead>
          <tr>
            <th>Название</th>
            <th>Поток</th>
            <th>Протокол</th>
            <th>Устройство</th>
            <th>Node устройства</th>
            <th>Архив устройства</th>
            <th>Архив, дней</th>
            <th>Включена</th>
            <th>Токены</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="camera in filteredCameras" :key="camera.id">
            <td>{{ camera.name }}</td>
            <td><code>{{ camera.stream_name }}</code></td>
            <td><v-chip size="small" :color="cameraProtocolColor(camera)">{{ cameraProtocolTitle(camera) }}</v-chip></td>
            <td>{{ camera.device_name || '—' }}</td>
            <td>{{ camera.dvr_server_name || '—' }}</td>
            <td>{{ archiveStorageTitle(camera.device_archive_storage || camera.archive_storage) }}</td>
            <td>{{ camera.retention_days }}</td>
            <td>
              <v-chip size="small" :color="camera.is_enabled ? 'success' : 'default'">
                {{ camera.is_enabled ? 'Да' : 'Нет' }}
              </v-chip>
            </td>
            <td style="min-width: 220px">
              <div v-if="canManageTokens" class="d-flex flex-wrap ga-1">
                <v-chip
                  v-for="token in camera.managed_tokens"
                  :key="token.id"
                  size="x-small"
                  variant="tonal"
                  :color="tokenChipColor(token)"
                  :title="tokenDescription(token)"
                >
                  {{ tokenDisplayName(token) }}
                </v-chip>
                <span v-if="!camera.managed_tokens.length" class="text-medium-emphasis">Нет привязок</span>
              </div>
              <span v-else class="text-medium-emphasis">—</span>
            </td>
            <td class="text-right" style="white-space: nowrap">
              <v-btn size="small" color="primary" variant="tonal" :to="`/cameras/${camera.id}`">Просмотр</v-btn>
              <v-btn
                v-if="canManageTokens"
                size="small"
                variant="tonal"
                class="ml-2"
                prepend-icon="mdi-key-chain"
                @click="openTokenDialog(camera)"
              >
                Токены
              </v-btn>
              <v-btn v-if="auth.isAdmin" size="small" variant="tonal" class="ml-2" @click="openEdit(camera)">
                Включение
              </v-btn>
            </td>
          </tr>
          <tr v-if="!filteredCameras.length">
            <td colspan="10" class="text-center text-medium-emphasis py-6">Камеры не найдены</td>
          </tr>
        </tbody>
      </v-table>
    </v-card>

    <v-dialog v-model="dialog" max-width="520">
      <v-card>
        <v-card-title>Камера: {{ editingCamera?.name }}</v-card-title>
        <v-card-text>
          <v-alert type="info" variant="tonal" density="compact" class="mb-4">
            Остальные параметры камеры редактируются внутри устройства «{{ editingCamera?.device_name || '—' }}».
          </v-alert>
          <v-switch v-model="form.is_enabled" color="primary" label="Камера включена" hide-details />
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn variant="tonal" @click="dialog = false">Отмена</v-btn>
          <v-btn color="primary" :loading="saving" @click="saveEnabled">Сохранить</v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>

    <v-dialog v-model="tokenDialog" max-width="760">
      <v-card>
        <v-card-title>Токены камеры: {{ tokenCamera?.name }}</v-card-title>
        <v-card-subtitle class="pb-3"><code>{{ tokenCamera?.stream_name }}</code></v-card-subtitle>
        <v-card-text>
          <v-alert type="info" variant="tonal" density="compact" class="mb-4">
            Выберите пользовательские токены, которые должны быть привязаны к камере. Токены с режимом
            «всем камерам» отмечены как автоматические и останутся привязанными, пока этот режим включён в администрировании.
          </v-alert>

          <v-select
            v-model="selectedTokenIds"
            :items="tokenOptions"
            item-title="title"
            item-value="value"
            item-props="props"
            label="Управляемые токены"
            multiple
            chips
            closable-chips
            clearable
            :loading="loadingTokens"
            no-data-text="Пользовательские токены не найдены"
          >
            <template #item="{ props, item }">
              <v-list-item v-bind="props" :subtitle="item.raw.subtitle" />
            </template>
          </v-select>

          <div v-if="systemTokenAssigned" class="mt-3">
            <v-chip size="small" variant="tonal" prepend-icon="mdi-shield-key">
              Внутренний системный fallback назначен автоматически
            </v-chip>
          </div>
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn variant="tonal" @click="tokenDialog = false">Отмена</v-btn>
          <v-btn color="primary" :loading="savingTokens" @click="saveTokenAssignments">Сохранить привязки</v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>
  </v-container>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import { api } from '../api';
import { useAuthStore } from '../stores/auth';

const SYSTEM_MANAGED_TOKEN_ID = '00000000-0000-4000-8000-000000000001';

const auth = useAuthStore();
const cameras = ref<any[]>([]);
const managedTokens = ref<any[]>([]);
const search = ref('');
const message = ref('');
const messageType = ref<'success' | 'error'>('success');
const dialog = ref(false);
const tokenDialog = ref(false);
const saving = ref(false);
const savingTokens = ref(false);
const loadingTokens = ref(false);
const editingCamera = ref<any | null>(null);
const tokenCamera = ref<any | null>(null);
const selectedTokenIds = ref<string[]>([]);
const form = reactive({ is_enabled: true });

const canManageTokens = computed(() => auth.user?.role === 'super_admin');

const filteredCameras = computed(() => {
  const needle = search.value.trim().toLowerCase();
  if (!needle) return cameras.value;
  return cameras.value.filter((camera) =>
    [
      camera.name,
      camera.stream_name,
      camera.device_name,
      camera.dvr_server_name,
      ...(camera.managed_tokens || []).map((token: any) => token.name)
    ].some((value) => String(value || '').toLowerCase().includes(needle))
  );
});

const assignedUserTokenIds = computed(() => new Set(
  (tokenCamera.value?.managed_tokens || [])
    .filter((token: any) => token.id !== SYSTEM_MANAGED_TOKEN_ID)
    .map((token: any) => token.id)
));

const lockedAutomaticTokenIds = computed(() => new Set(
  (tokenCamera.value?.managed_tokens || [])
    .filter((token: any) => token.id !== SYSTEM_MANAGED_TOKEN_ID && token.auto_assign_new_cameras)
    .map((token: any) => token.id)
));

const systemTokenAssigned = computed(() => Boolean(
  (tokenCamera.value?.managed_tokens || []).some((token: any) => token.id === SYSTEM_MANAGED_TOKEN_ID)
));

const tokenOptions = computed(() => managedTokens.value
  .filter((token) => token.id !== SYSTEM_MANAGED_TOKEN_ID)
  .filter((token) => token.scopes?.includes('camera'))
  .map((token) => {
    const assigned = assignedUserTokenIds.value.has(token.id);
    const automatic = Boolean(token.auto_assign_new_cameras);
    const usable = isTokenUsable(token);
    return {
      value: token.id,
      title: automatic ? `${token.name} · автоматически всем камерам` : token.name,
      subtitle: tokenDescription(token),
      props: {
        disabled: automatic || (!usable && !assigned)
      }
    };
  }));

function notify(text: string, type: 'success' | 'error' = 'success') {
  message.value = text;
  messageType.value = type;
}

function cameraProtocolTitle(camera: any) {
  if (camera.device_connection_type === 'HIKVISION') return 'HIKVISION';
  return camera.is_onvif ? 'ONVIF' : 'RTSP';
}

function cameraProtocolColor(camera: any) {
  if (camera.device_connection_type === 'HIKVISION') return 'deep-orange';
  return camera.is_onvif ? 'indigo' : 'blue';
}

function archiveStorageTitle(value: string) {
  if (value === 'device') return 'Устройство';
  if (value === 'both') return 'Node + устройство';
  return 'Node';
}

function isTokenUsable(token: any) {
  if (!token?.is_active) return false;
  if (!token.scopes?.includes('camera')) return false;
  return !token.expires_at || new Date(token.expires_at).getTime() > Date.now();
}

function tokenDescription(token: any) {
  const status = !token.is_active
    ? 'отключён'
    : token.expires_at && new Date(token.expires_at).getTime() <= Date.now()
      ? 'истёк'
      : token.scopes?.includes('camera')
        ? 'активен'
        : 'нет права на видео';
  const expiry = token.expires_at ? `до ${new Date(token.expires_at).toLocaleString()}` : 'без срока';
  const automatic = token.auto_assign_new_cameras ? ' · автоматически всем камерам' : '';
  return `${status} · ${expiry}${automatic}`;
}

function tokenDisplayName(token: any) {
  if (token.id === SYSTEM_MANAGED_TOKEN_ID) return 'Системный fallback';
  return token.auto_assign_new_cameras ? `${token.name} · авто` : token.name;
}

function tokenChipColor(token: any) {
  if (token.id === SYSTEM_MANAGED_TOKEN_ID) return 'default';
  if (!isTokenUsable(token)) return 'warning';
  return token.auto_assign_new_cameras ? 'primary' : 'success';
}

async function load() {
  const cameraResponse = await api.get('/cameras');
  const cameraItems = cameraResponse.data.items || [];

  if (!canManageTokens.value) {
    managedTokens.value = [];
    cameras.value = cameraItems.map((camera: any) => ({ ...camera, managed_tokens: [] }));
    return;
  }

  loadingTokens.value = true;
  try {
    const tokenResponse = await api.get('/tokens/managed-camera-tokens');
    const tokens = tokenResponse.data.items || [];
    const assignments = new Map<string, any[]>();

    for (const token of tokens) {
      for (const camera of token.assigned_cameras || []) {
        const list = assignments.get(camera.id) || [];
        list.push(token);
        assignments.set(camera.id, list);
      }
    }

    managedTokens.value = tokens;
    cameras.value = cameraItems.map((camera: any) => ({
      ...camera,
      managed_tokens: assignments.get(camera.id) || []
    }));
  } finally {
    loadingTokens.value = false;
  }
}

function openEdit(camera: any) {
  editingCamera.value = camera;
  form.is_enabled = Boolean(camera.is_enabled);
  dialog.value = true;
}

function openTokenDialog(camera: any) {
  tokenCamera.value = camera;
  selectedTokenIds.value = (camera.managed_tokens || [])
    .filter((token: any) => token.id !== SYSTEM_MANAGED_TOKEN_ID)
    .map((token: any) => token.id);
  tokenDialog.value = true;
}

async function saveEnabled() {
  if (!editingCamera.value) return;
  saving.value = true;
  try {
    await api.patch(`/cameras/${editingCamera.value.id}`, { is_enabled: form.is_enabled });
    dialog.value = false;
    notify(form.is_enabled ? 'Камера включена' : 'Камера отключена');
    await load();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка изменения камеры', 'error');
  } finally {
    saving.value = false;
  }
}

async function saveTokenAssignments() {
  if (!tokenCamera.value) return;
  savingTokens.value = true;
  try {
    const desired = new Set([...selectedTokenIds.value, ...lockedAutomaticTokenIds.value]);
    const existing = assignedUserTokenIds.value;
    const toAdd = [...desired].filter((id) => !existing.has(id));
    const toRemove = [...existing].filter((id) => !desired.has(id) && !lockedAutomaticTokenIds.value.has(id));

    for (const tokenId of toAdd) {
      await api.post(`/tokens/camera-links/${tokenCamera.value.id}`, { managed_token_id: tokenId });
    }
    for (const tokenId of toRemove) {
      await api.delete(`/tokens/managed-camera-tokens/${tokenId}/cameras/${tokenCamera.value.id}`);
    }

    tokenDialog.value = false;
    notify(`Привязки сохранены: добавлено ${toAdd.length}, удалено ${toRemove.length}`);
    await load();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Не удалось сохранить привязки токенов', 'error');
  } finally {
    savingTokens.value = false;
  }
}

onMounted(load);
</script>
