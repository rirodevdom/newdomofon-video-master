<template>
  <v-container fluid class="pa-6">
    <div class="d-flex align-center mb-4 flex-wrap ga-2">
      <h1 class="text-h4">Устройства</h1>
      <v-spacer />
      <v-text-field v-model="search" density="compact" label="Поиск" hide-details style="max-width: 280px" />
      <v-btn v-if="auth.isAdmin" color="primary" prepend-icon="mdi-plus" @click="openCreate">Добавить</v-btn>
    </div>

    <v-alert type="info" variant="tonal" class="mb-4">
      Обычная video node работает с RTSP и ONVIF. Live и архив всегда записываются на назначенную video node.
      Vendor-specific Hikvision/ISAPI функции вынесены из этого проекта.
    </v-alert>

    <v-alert v-if="message" :type="messageType" variant="tonal" class="mb-4" closable @click:close="message = ''">
      {{ message }}
    </v-alert>

    <v-card>
      <v-table>
        <thead>
          <tr>
            <th>Название</th>
            <th>Тип</th>
            <th>Node</th>
            <th>Камер</th>
            <th>Настройка</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="device in filteredDevices" :key="device.id" :class="{ 'bg-red-lighten-5': !device.is_configured }">
            <td>
              <div class="font-weight-medium">{{ device.name || '—' }}</div>
              <div v-if="!device.is_enabled" class="text-caption text-medium-emphasis">Устройство отключено</div>
            </td>
            <td>{{ device.connection_type }}</td>
            <td>{{ device.node_name || '—' }}</td>
            <td>{{ device.camera_count }}</td>
            <td>
              <v-chip size="small" :color="device.is_configured ? 'success' : 'error'">
                {{ device.is_configured ? 'Настроено' : 'Не донастроено' }}
              </v-chip>
            </td>
            <td class="text-right" style="white-space: nowrap">
              <v-btn size="small" variant="tonal" @click="openView(device)">Камеры</v-btn>
              <v-btn v-if="auth.isAdmin" size="small" variant="tonal" class="ml-2" @click="openEdit(device)">Редактировать</v-btn>
              <v-btn v-if="auth.user?.role === 'super_admin'" size="small" color="error" variant="tonal" class="ml-2" @click="remove(device)">Удалить</v-btn>
            </td>
          </tr>
          <tr v-if="!filteredDevices.length">
            <td colspan="6" class="text-center text-medium-emphasis py-6">Устройства не найдены</td>
          </tr>
        </tbody>
      </v-table>
    </v-card>

    <v-dialog v-model="formDialog" max-width="900">
      <v-card>
        <v-card-title>{{ editingId ? 'Редактирование устройства' : 'Новое устройство' }}</v-card-title>
        <v-card-text>
          <v-row>
            <v-col cols="12" md="6"><v-text-field v-model="form.name" label="Название устройства" /></v-col>
            <v-col cols="12" md="3"><v-select v-model="form.connection_type" :items="connectionTypes" label="Тип подключения" /></v-col>
            <v-col cols="12" md="3"><v-switch v-model="form.is_enabled" color="primary" label="Устройство включено" /></v-col>
            <v-col cols="12" md="6"><v-select v-model="form.dvr_server_id" :items="nodes" item-title="name" item-value="id" label="Video node" clearable /></v-col>
            <v-col cols="12" md="6">
              <v-text-field model-value="Локальный архив video node" label="Хранение архива" readonly />
            </v-col>
            <v-col cols="12">
              <v-alert type="info" variant="tonal" density="compact">
                Назначенная node автоматически применяется ко всем камерам устройства.
              </v-alert>
            </v-col>
            <v-col cols="12" md="6"><v-text-field v-model="form.host" label="Host/IP" /></v-col>
            <v-col cols="12" md="2"><v-text-field v-model.number="form.port" label="Port" type="number" /></v-col>
            <v-col cols="12" md="4"><v-text-field v-model="form.username" label="Login" autocomplete="off" /></v-col>
            <v-col cols="12" md="6"><v-text-field v-model="form.password" label="Password" type="password" autocomplete="new-password" /></v-col>
            <v-col v-if="form.connection_type === 'RTSP'" cols="12"><v-text-field v-model="form.rtsp_url" label="Базовый RTSP URL" /></v-col>
            <v-col cols="12"><v-textarea v-model="form.comment" label="Комментарий" rows="2" /></v-col>
          </v-row>
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn variant="tonal" @click="formDialog = false">Отмена</v-btn>
          <v-btn color="primary" :loading="saving" @click="save">Сохранить</v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>

    <v-dialog v-model="viewDialog" max-width="1120">
      <v-card>
        <v-card-title>Камеры устройства: {{ selectedDevice?.name }}</v-card-title>
        <v-card-subtitle class="pb-3">Node: {{ selectedDevice?.node_name || 'не назначена' }} · Архив: Node</v-card-subtitle>
        <v-card-text>
          <div class="d-flex justify-end mb-3">
            <v-btn v-if="auth.isAdmin" color="primary" prepend-icon="mdi-plus" @click="openCameraCreate">Добавить камеру</v-btn>
          </div>

          <v-table>
            <thead>
              <tr>
                <th>Название</th>
                <th>Поток</th>
                <th>Протокол</th>
                <th>Включена</th>
                <th>Архив, дней</th>
                <th>Node</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="camera in deviceCameras" :key="camera.id">
                <td>{{ camera.name }}</td>
                <td><code>{{ camera.stream_name }}</code></td>
                <td>{{ camera.is_onvif ? 'ONVIF' : 'RTSP' }}</td>
                <td>
                  <v-switch
                    v-if="auth.isAdmin"
                    :model-value="camera.is_enabled"
                    color="primary"
                    density="compact"
                    hide-details
                    :loading="togglingCamera === camera.id"
                    @update:model-value="toggleCamera(camera, Boolean($event))"
                  />
                  <span v-else>{{ camera.is_enabled ? 'Да' : 'Нет' }}</span>
                </td>
                <td>{{ camera.retention_days }}</td>
                <td>{{ camera.node_name || '—' }}</td>
                <td class="text-right" style="white-space: nowrap">
                  <v-btn size="small" :to="`/cameras/${camera.id}`">Просмотр</v-btn>
                  <v-btn v-if="auth.isAdmin" size="small" variant="tonal" class="ml-2" @click="openCameraEdit(camera)">Настроить</v-btn>
                  <v-btn v-if="auth.user?.role === 'super_admin'" size="small" color="error" variant="text" icon="mdi-delete-outline" title="Удалить камеру" @click="removeCamera(camera)" />
                </td>
              </tr>
              <tr v-if="!deviceCameras.length">
                <td colspan="7" class="text-center text-medium-emphasis py-6">Камеры к устройству не привязаны</td>
              </tr>
            </tbody>
          </v-table>
        </v-card-text>
        <v-card-actions><v-spacer /><v-btn variant="tonal" @click="viewDialog = false">Закрыть</v-btn></v-card-actions>
      </v-card>
    </v-dialog>

    <v-dialog v-model="cameraDialog" max-width="900">
      <v-card>
        <v-card-title>{{ cameraEditingId ? 'Настройка камеры' : 'Новая камера' }}</v-card-title>
        <v-card-subtitle class="pb-3">Устройство: {{ selectedDevice?.name }} · Node наследуется автоматически</v-card-subtitle>
        <v-card-text>
          <v-alert type="info" variant="tonal" density="compact" class="mb-4">
            Live и архив камеры обслуживает video node «{{ selectedDevice?.node_name || 'не назначена' }}».
          </v-alert>
          <v-row>
            <v-col cols="12" md="6"><v-text-field v-model="cameraForm.name" label="Название камеры" /></v-col>
            <v-col cols="12" md="6">
              <v-text-field
                v-model="cameraForm.stream_name"
                label="Stream name"
                hint="Только латинские буквы, цифры, _ и -. Остальные символы заменяются на _."
                persistent-hint
              />
            </v-col>
            <v-col cols="12" md="6"><v-text-field v-model.number="cameraForm.retention_days" label="Архив, дней" type="number" min="1" max="365" /></v-col>
            <v-col cols="12" md="6"><v-switch v-model="cameraForm.is_enabled" color="primary" label="Камера включена" /></v-col>
            <v-col v-if="!cameraEditingId && auth.user?.role === 'super_admin'" cols="12">
              <v-select
                v-model="cameraForm.managed_token_id"
                :items="managedTokenOptions"
                item-title="title"
                item-value="value"
                label="Пользовательский токен доступа"
                hint="Необязательно. Без выбора будет назначен внутренний системный токен."
                persistent-hint
                clearable
                :loading="loadingManagedTokens"
                no-data-text="Рабочие пользовательские токены ещё не созданы"
              />
            </v-col>

            <template v-if="selectedDevice?.connection_type === 'ONVIF'">
              <v-col cols="12">
                <v-alert type="warning" variant="tonal" density="compact">
                  Host, port, login и password берутся из устройства. Кнопка получает RTSP URI и profile token через назначенную video node.
                </v-alert>
              </v-col>
              <v-col cols="12" md="8"><v-text-field v-model="cameraForm.source_url" label="Полученный RTSP URI" readonly /></v-col>
              <v-col cols="12" md="4" class="d-flex align-center">
                <v-btn color="primary" variant="tonal" block :loading="resolvingOnvif" @click="resolveOnvifStream">Получить поток ONVIF</v-btn>
              </v-col>
              <v-col cols="12" md="6"><v-text-field v-model="cameraForm.onvif_xaddr" label="ONVIF XAddr" readonly /></v-col>
              <v-col cols="12" md="6"><v-text-field v-model="cameraForm.onvif_profile_token" label="Profile token" readonly /></v-col>
            </template>

            <v-col v-else cols="12"><v-text-field v-model="cameraForm.source_url" label="RTSP URL" placeholder="rtsp://host:554/path" /></v-col>
          </v-row>
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn variant="tonal" @click="cameraDialog = false">Отмена</v-btn>
          <v-btn color="primary" :loading="savingCamera" @click="saveCamera">Сохранить</v-btn>
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
const devices = ref<any[]>([]);
const nodes = ref<any[]>([]);
const managedTokens = ref<any[]>([]);
const deviceCameras = ref<any[]>([]);
const selectedDevice = ref<any | null>(null);
const search = ref('');
const message = ref('');
const messageType = ref<'success' | 'error'>('success');
const formDialog = ref(false);
const viewDialog = ref(false);
const cameraDialog = ref(false);
const saving = ref(false);
const savingCamera = ref(false);
const loadingManagedTokens = ref(false);
const resolvingOnvif = ref(false);
const togglingCamera = ref<string | null>(null);
const editingId = ref<string | null>(null);
const cameraEditingId = ref<string | null>(null);
const connectionTypes = ['RTSP', 'ONVIF'];

const form = reactive<any>({
  name: '',
  connection_type: 'RTSP',
  dvr_server_id: null,
  host: '',
  port: null,
  username: '',
  password: '',
  rtsp_url: '',
  comment: '',
  is_enabled: true
});

const cameraForm = reactive<any>({
  name: '',
  stream_name: '',
  source_url: '',
  retention_days: 7,
  is_enabled: true,
  managed_token_id: null,
  group_id: null,
  onvif_xaddr: null,
  onvif_port: null,
  onvif_username: null,
  onvif_password: null,
  onvif_profile_token: null,
  onvif_device_info: null,
  onvif_last_sync_at: null
});

const managedTokenOptions = computed(() => managedTokens.value
  .filter((token) => token.id !== SYSTEM_MANAGED_TOKEN_ID)
  .filter((token) => token.is_active && token.scopes?.includes('camera'))
  .filter((token) => !token.expires_at || new Date(token.expires_at).getTime() > Date.now())
  .map((token) => ({
    title: token.expires_at ? `${token.name} · до ${new Date(token.expires_at).toLocaleString()}` : `${token.name} · без срока`,
    value: token.id
  })));

const filteredDevices = computed(() => {
  const needle = search.value.trim().toLowerCase();
  if (!needle) return devices.value;
  return devices.value.filter((device) =>
    [device.name, device.connection_type, device.node_name, device.host, device.rtsp_url]
      .some((value) => String(value || '').toLowerCase().includes(needle))
  );
});

function normalizeStreamName(value: unknown): string {
  return String(value || '')
    .trim()
    .replace(/[^a-zA-Z0-9_-]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 255);
}

function resetForm() {
  Object.assign(form, {
    name: '', connection_type: 'RTSP', dvr_server_id: null,
    host: '', port: null, username: '', password: '', rtsp_url: '', comment: '', is_enabled: true
  });
}

function resetCameraForm() {
  Object.assign(cameraForm, {
    name: '', stream_name: '', source_url: selectedDevice.value?.rtsp_url || '', retention_days: 7,
    is_enabled: true, managed_token_id: null, group_id: null, onvif_xaddr: null, onvif_port: null,
    onvif_username: null, onvif_password: null, onvif_profile_token: null,
    onvif_device_info: null, onvif_last_sync_at: null
  });
}

function notify(text: string, type: 'success' | 'error' = 'success') {
  message.value = text;
  messageType.value = type;
}

async function loadManagedTokens() {
  if (auth.user?.role !== 'super_admin') {
    managedTokens.value = [];
    return;
  }
  loadingManagedTokens.value = true;
  try {
    managedTokens.value = (await api.get('/tokens/managed-camera-tokens')).data.items || [];
  } catch (err: any) {
    managedTokens.value = [];
    notify(err.response?.data?.error || err.message || 'Не удалось загрузить токены', 'error');
  } finally {
    loadingManagedTokens.value = false;
  }
}

async function load() {
  const [devicesResponse, nodesResponse] = await Promise.all([
    api.get('/devices'),
    api.get('/dvr-servers')
  ]);
  devices.value = devicesResponse.data.items || [];
  nodes.value = nodesResponse.data.items || [];
  await loadManagedTokens();
}

function openCreate() {
  editingId.value = null;
  resetForm();
  formDialog.value = true;
}

function openEdit(device: any) {
  editingId.value = device.id;
  Object.assign(form, {
    name: device.name || '',
    connection_type: device.connection_type === 'ONVIF' ? 'ONVIF' : 'RTSP',
    dvr_server_id: device.dvr_server_id || null,
    host: device.host || '',
    port: device.port || null,
    username: device.username || '',
    password: '',
    rtsp_url: device.rtsp_url || '',
    comment: device.comment || '',
    is_enabled: device.is_enabled !== false
  });
  formDialog.value = true;
}

async function openView(device: any) {
  const { data } = await api.get(`/devices/${device.id}`);
  selectedDevice.value = data.item;
  deviceCameras.value = data.cameras || [];
  viewDialog.value = true;
}

async function openCameraCreate() {
  if (!selectedDevice.value) return;
  cameraEditingId.value = null;
  resetCameraForm();
  await loadManagedTokens();
  cameraDialog.value = true;
}

function openCameraEdit(camera: any) {
  cameraEditingId.value = camera.id;
  Object.assign(cameraForm, {
    name: camera.name || '',
    stream_name: camera.stream_name || '',
    source_url: camera.source_url || '',
    retention_days: Number(camera.retention_days || 7),
    is_enabled: camera.is_enabled !== false,
    managed_token_id: null,
    group_id: camera.group_id || null,
    onvif_xaddr: camera.onvif_xaddr || null,
    onvif_port: camera.onvif_port || selectedDevice.value?.port || null,
    onvif_username: camera.onvif_username || selectedDevice.value?.username || null,
    onvif_password: null,
    onvif_profile_token: camera.onvif_profile_token || null,
    onvif_device_info: camera.onvif_device_info || null,
    onvif_last_sync_at: camera.onvif_last_sync_at || null
  });
  cameraDialog.value = true;
}

async function resolveOnvifStream() {
  if (!selectedDevice.value) return false;
  resolvingOnvif.value = true;
  try {
    const { data } = await api.post('/onvif/stream-uri', { device_id: selectedDevice.value.id });
    cameraForm.source_url = data.streamUri || '';
    cameraForm.onvif_xaddr = data.xaddr || `http://${selectedDevice.value.host}:${selectedDevice.value.port || 80}/onvif/device_service`;
    cameraForm.onvif_port = selectedDevice.value.port || 80;
    cameraForm.onvif_username = selectedDevice.value.username || null;
    cameraForm.onvif_profile_token = data.selectedProfileToken || null;
    cameraForm.onvif_device_info = data.information || null;
    cameraForm.onvif_last_sync_at = new Date().toISOString();
    notify('ONVIF stream URI получен автоматически');
    return Boolean(cameraForm.source_url);
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'ONVIF подключение не удалось', 'error');
    return false;
  } finally {
    resolvingOnvif.value = false;
  }
}

async function saveCamera() {
  if (!selectedDevice.value) return;
  savingCamera.value = true;
  try {
    const normalizedStreamName = normalizeStreamName(cameraForm.stream_name);
    cameraForm.stream_name = normalizedStreamName;
    if (!cameraForm.name.trim() || !normalizedStreamName) {
      notify('Укажите название и корректный stream name камеры', 'error');
      return;
    }

    if (selectedDevice.value.connection_type === 'ONVIF' && !cameraForm.source_url) {
      const resolved = await resolveOnvifStream();
      if (!resolved) return;
    }
    if (!cameraForm.source_url) {
      notify('Укажите RTSP URL камеры', 'error');
      return;
    }

    const payload: Record<string, unknown> = {
      name: cameraForm.name,
      stream_name: normalizedStreamName,
      source_url: cameraForm.source_url,
      retention_days: Number(cameraForm.retention_days || 7),
      is_enabled: Boolean(cameraForm.is_enabled),
      group_id: cameraForm.group_id || null
    };

    if (selectedDevice.value.connection_type === 'ONVIF') {
      Object.assign(payload, {
        onvif_xaddr: cameraForm.onvif_xaddr,
        onvif_port: Number(cameraForm.onvif_port || selectedDevice.value.port || 80),
        onvif_username: cameraForm.onvif_username || selectedDevice.value.username || null,
        onvif_password: null,
        onvif_profile_token: cameraForm.onvif_profile_token,
        onvif_device_info: cameraForm.onvif_device_info,
        onvif_last_sync_at: cameraForm.onvif_last_sync_at,
        _onvif_requery: true
      });
    } else {
      Object.assign(payload, {
        onvif_xaddr: null,
        onvif_port: null,
        onvif_username: null,
        onvif_password: null,
        onvif_profile_token: null,
        onvif_device_info: null,
        onvif_last_sync_at: null
      });
    }

    let tokenAssignmentError: string | null = null;
    if (cameraEditingId.value) {
      await api.patch(`/cameras/${cameraEditingId.value}/config`, payload);
    } else {
      const response = await api.post('/cameras', { ...payload, device_id: selectedDevice.value.id });
      const createdCameraId = response.data?.id || null;
      if (createdCameraId && cameraForm.managed_token_id) {
        try {
          await api.post(`/tokens/camera-links/${createdCameraId}`, { managed_token_id: cameraForm.managed_token_id });
        } catch (err: any) {
          tokenAssignmentError = err.response?.data?.error || err.message || 'неизвестная ошибка привязки токена';
        }
      }
    }

    cameraDialog.value = false;
    if (cameraEditingId.value) {
      notify('Настройки камеры сохранены');
    } else if (tokenAssignmentError) {
      notify(`Камера создана, но пользовательский токен не назначен: ${tokenAssignmentError}. Оставлен системный токен.`, 'error');
    } else if (cameraForm.managed_token_id) {
      notify('Камера создана; выбранный пользовательский токен заменил системный fallback');
    } else {
      notify('Камера создана; назначен внутренний системный токен');
    }
    await openView(selectedDevice.value);
    await load();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка сохранения камеры', 'error');
  } finally {
    savingCamera.value = false;
  }
}

async function toggleCamera(camera: any, enabled: boolean) {
  togglingCamera.value = camera.id;
  try {
    await api.patch(`/cameras/${camera.id}`, { is_enabled: enabled });
    camera.is_enabled = enabled;
    notify(enabled ? 'Камера включена' : 'Камера отключена');
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Не удалось изменить состояние камеры', 'error');
    await openView(selectedDevice.value);
  } finally {
    togglingCamera.value = null;
  }
}

async function removeCamera(camera: any) {
  if (!confirm(`Удалить камеру «${camera.name}»?`)) return;
  try {
    await api.delete(`/cameras/${camera.id}`);
    notify('Камера удалена');
    await openView(selectedDevice.value);
    await load();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Не удалось удалить камеру', 'error');
  }
}

async function save() {
  saving.value = true;
  const payload = { ...form };
  if (!payload.password) delete payload.password;
  try {
    if (editingId.value) await api.patch(`/devices/${editingId.value}`, payload);
    else await api.post('/devices', payload);
    formDialog.value = false;
    notify('Устройство сохранено; назначенная node применена ко всем его камерам');
    await load();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка сохранения устройства', 'error');
  } finally {
    saving.value = false;
  }
}

async function remove(device: any) {
  if (!confirm(`Удалить устройство «${device.name}» и все его камеры?`)) return;
  try {
    await api.delete(`/devices/${device.id}`);
    notify('Устройство удалено');
    await load();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка удаления устройства', 'error');
  }
}

onMounted(load);
</script>
