<template>
  <v-container fluid class="pa-6">
    <div class="d-flex align-center mb-4 flex-wrap ga-2">
      <h1 class="text-h4">Устройства</h1>
      <v-spacer />
      <v-text-field v-model="search" density="compact" label="Поиск" hide-details style="max-width: 280px" />
      <v-btn v-if="auth.isAdmin" color="primary" prepend-icon="mdi-plus" @click="openCreate">Добавить</v-btn>
    </div>

    <v-alert type="info" variant="tonal" class="mb-4">
      Video node и место хранения архива задаются на устройстве и автоматически применяются ко всем его камерам.
      Отдельно поменять node или архив у камеры нельзя.
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
            <th>Архив</th>
            <th>Node</th>
            <th>Камер/каналов</th>
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
            <td>{{ archiveStorageTitle(device.archive_storage) }}</td>
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
            <td colspan="7" class="text-center text-medium-emphasis py-6">Устройства не найдены</td>
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
            <v-col cols="12" md="6"><v-select v-model="form.archive_storage" :items="archiveStorageItems" label="Где хранится архив" /></v-col>
            <v-col cols="12">
              <v-alert type="info" variant="tonal" density="compact">
                Эти два значения наследуются всеми камерами устройства. При изменении node или места хранения backend синхронизирует все каналы и отправляет reload старой и новой node.
              </v-alert>
            </v-col>
            <v-col v-if="form.connection_type === 'HIKVISION'" cols="12">
              <v-alert type="warning" variant="tonal" density="compact">
                Для Hikvision укажите Host/IP, ISAPI port и учётные данные. Каналы можно найти автоматически после сохранения устройства.
              </v-alert>
            </v-col>
            <v-col cols="12" md="6"><v-text-field v-model="form.host" :label="form.connection_type === 'HIKVISION' ? 'Hikvision Host/IP' : 'Host/IP'" /></v-col>
            <v-col cols="12" md="2"><v-text-field v-model.number="form.port" label="Port" type="number" /></v-col>
            <v-col cols="12" md="4"><v-text-field v-model="form.username" label="Login" autocomplete="off" /></v-col>
            <v-col cols="12" md="6"><v-text-field v-model="form.password" label="Password" type="password" autocomplete="new-password" /></v-col>
            <v-col v-if="form.connection_type !== 'ONVIF'" cols="12"><v-text-field v-model="form.rtsp_url" :label="form.connection_type === 'HIKVISION' ? 'Базовый RTSP URL' : 'RTSP URL'" /></v-col>
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
        <v-card-subtitle class="pb-3">
          Node: {{ selectedDevice?.node_name || 'не назначена' }} · Архив: {{ archiveStorageTitle(selectedDevice?.archive_storage) }}
        </v-card-subtitle>
        <v-card-text>
          <div class="d-flex justify-end mb-3 flex-wrap ga-2">
            <template v-if="selectedDevice?.connection_type === 'HIKVISION'">
              <v-btn color="deep-orange" variant="tonal" prepend-icon="mdi-magnify" :loading="discoveringChannels" @click="discoverHikvisionChannels('auto')">
                Авто-поиск каналов
              </v-btn>
              <v-text-field v-model.number="manualFirstChannel" density="compact" label="С" type="number" hide-details style="max-width: 90px" />
              <v-text-field v-model.number="manualLastChannel" density="compact" label="По" type="number" hide-details style="max-width: 90px" />
              <v-btn variant="tonal" prepend-icon="mdi-playlist-plus" :loading="discoveringChannels" @click="discoverHikvisionChannels('manual')">
                Найти диапазон
              </v-btn>
            </template>
            <v-btn v-if="auth.isAdmin" color="primary" prepend-icon="mdi-plus" @click="openCameraCreate">
              Добавить камеру
            </v-btn>
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
                <th>Архив</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="camera in deviceCameras" :key="camera.id">
                <td>{{ camera.name }}</td>
                <td><code>{{ camera.stream_name }}</code></td>
                <td>{{ cameraProtocolTitle(camera) }}</td>
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
                <td>{{ archiveStorageTitle(camera.archive_storage) }}</td>
                <td class="text-right" style="white-space: nowrap">
                  <v-btn size="small" :to="`/cameras/${camera.id}`">Просмотр</v-btn>
                  <v-btn v-if="auth.isAdmin" size="small" variant="tonal" class="ml-2" @click="openCameraEdit(camera)">Настроить</v-btn>
                  <v-btn v-if="auth.user?.role === 'super_admin'" size="small" color="error" variant="text" icon="mdi-delete-outline" title="Удалить камеру" @click="removeCamera(camera)" />
                </td>
              </tr>
              <tr v-if="!deviceCameras.length">
                <td colspan="8" class="text-center text-medium-emphasis py-6">Камеры к устройству не привязаны</td>
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
        <v-card-subtitle class="pb-3">
          Устройство: {{ selectedDevice?.name }} · Node и архив наследуются автоматически
        </v-card-subtitle>
        <v-card-text>
          <v-alert type="info" variant="tonal" density="compact" class="mb-4">
            Node «{{ selectedDevice?.node_name || 'не назначена' }}» и архив «{{ archiveStorageTitle(selectedDevice?.archive_storage) }}» меняются только в настройках устройства.
          </v-alert>
          <v-row>
            <v-col cols="12" md="6"><v-text-field v-model="cameraForm.name" label="Название камеры" /></v-col>
            <v-col cols="12" md="6"><v-text-field v-model="cameraForm.stream_name" label="Stream name" /></v-col>
            <v-col cols="12" md="6"><v-text-field v-model.number="cameraForm.retention_days" label="Архив, дней" type="number" min="1" max="365" /></v-col>
            <v-col cols="12" md="6"><v-switch v-model="cameraForm.is_enabled" color="primary" label="Камера включена" /></v-col>

            <template v-if="selectedDevice?.connection_type === 'ONVIF'">
              <v-col cols="12">
                <v-alert type="warning" variant="tonal" density="compact">
                  ONVIF Host, port, login и password берутся из устройства. Кнопка ниже получает RTSP URI и profile token через назначенную video node.
                </v-alert>
              </v-col>
              <v-col cols="12" md="8"><v-text-field v-model="cameraForm.source_url" label="Полученный RTSP URI" readonly /></v-col>
              <v-col cols="12" md="4" class="d-flex align-center">
                <v-btn color="primary" variant="tonal" block :loading="resolvingOnvif" @click="resolveOnvifStream">
                  Получить поток ONVIF
                </v-btn>
              </v-col>
              <v-col cols="12" md="6"><v-text-field v-model="cameraForm.onvif_xaddr" label="ONVIF XAddr" readonly /></v-col>
              <v-col cols="12" md="6"><v-text-field v-model="cameraForm.onvif_profile_token" label="Profile token" readonly /></v-col>
            </template>

            <template v-else>
              <v-col cols="12">
                <v-text-field
                  v-model="cameraForm.source_url"
                  :label="selectedDevice?.connection_type === 'HIKVISION' ? 'RTSP URL канала' : 'RTSP URL'"
                  placeholder="rtsp://host:554/path"
                />
              </v-col>
            </template>
          </v-row>
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn variant="tonal" @click="cameraDialog = false">Отмена</v-btn>
          <v-btn color="primary" :loading="savingCamera" @click="saveCamera">Сохранить</v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>

    <v-dialog v-model="channelsDialog" max-width="980">
      <v-card>
        <v-card-title>Найденные каналы: {{ selectedDevice?.name }}</v-card-title>
        <v-card-text>
          <v-alert v-if="!discoveredChannels.length" type="warning" variant="tonal" class="mb-3">
            Каналы не найдены. Проверьте права пользователя Hikvision на ISAPI или используйте ручной диапазон.
          </v-alert>
          <v-table v-else>
            <thead>
              <tr>
                <th>Канал</th>
                <th>Track ID</th>
                <th>Название</th>
                <th>Online</th>
                <th>Источник</th>
                <th>Состояние</th>
                <th>RTSP</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="channel in discoveredChannels" :key="channel.track_id">
                <td>{{ channel.channel }}</td>
                <td><code>{{ channel.track_id }}</code></td>
                <td>{{ channel.name }}</td>
                <td>{{ channel.online === true ? 'online' : channel.online === false ? 'offline' : 'unknown' }}</td>
                <td>{{ channel.discovered_by }}</td>
                <td><v-chip size="small" :color="channel.exists ? 'info' : 'primary'">{{ channel.exists ? 'уже есть' : 'будет создан' }}</v-chip></td>
                <td><code>{{ channel.source_url }}</code></td>
              </tr>
            </tbody>
          </v-table>
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn variant="tonal" @click="channelsDialog = false">Закрыть</v-btn>
          <v-btn color="primary" :disabled="!discoveredChannels.some((channel) => !channel.exists)" :loading="syncingChannels" @click="syncHikvisionChannels">
            Создать отсутствующие
          </v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>
  </v-container>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import { api } from '../api';
import { useAuthStore } from '../stores/auth';

const auth = useAuthStore();
const devices = ref<any[]>([]);
const nodes = ref<any[]>([]);
const deviceCameras = ref<any[]>([]);
const selectedDevice = ref<any | null>(null);
const search = ref('');
const message = ref('');
const messageType = ref<'success' | 'error'>('success');
const formDialog = ref(false);
const viewDialog = ref(false);
const cameraDialog = ref(false);
const channelsDialog = ref(false);
const saving = ref(false);
const savingCamera = ref(false);
const resolvingOnvif = ref(false);
const togglingCamera = ref<string | null>(null);
const discoveringChannels = ref(false);
const syncingChannels = ref(false);
const editingId = ref<string | null>(null);
const cameraEditingId = ref<string | null>(null);
const discoveredChannels = ref<any[]>([]);
const manualFirstChannel = ref(1);
const manualLastChannel = ref(16);
const connectionTypes = ['RTSP', 'ONVIF', 'HIKVISION'];
const archiveStorageItems = [
  { title: 'На video node', value: 'node' },
  { title: 'На устройстве Hikvision/NVR', value: 'device' },
  { title: 'Node + устройство', value: 'both' }
];

const form = reactive<any>({
  name: '',
  connection_type: 'RTSP',
  archive_storage: 'node',
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
  group_id: null,
  onvif_xaddr: null,
  onvif_port: null,
  onvif_username: null,
  onvif_password: null,
  onvif_profile_token: null,
  onvif_device_info: null,
  onvif_last_sync_at: null
});

const filteredDevices = computed(() => {
  const needle = search.value.trim().toLowerCase();
  if (!needle) return devices.value;
  return devices.value.filter((device) =>
    [device.name, device.connection_type, device.node_name, device.host, device.rtsp_url]
      .some((value) => String(value || '').toLowerCase().includes(needle))
  );
});

function resetForm() {
  Object.assign(form, {
    name: '', connection_type: 'RTSP', archive_storage: 'node', dvr_server_id: null,
    host: '', port: null, username: '', password: '', rtsp_url: '', comment: '', is_enabled: true
  });
}

function resetCameraForm() {
  Object.assign(cameraForm, {
    name: '', stream_name: '', source_url: selectedDevice.value?.rtsp_url || '', retention_days: 7,
    is_enabled: true, group_id: null, onvif_xaddr: null, onvif_port: null,
    onvif_username: null, onvif_password: null, onvif_profile_token: null,
    onvif_device_info: null, onvif_last_sync_at: null
  });
}

function notify(text: string, type: 'success' | 'error' = 'success') {
  message.value = text;
  messageType.value = type;
}

function archiveStorageTitle(value: string | null | undefined) {
  if (value === 'device') return 'Устройство';
  if (value === 'both') return 'Node + устройство';
  return 'Node';
}

function cameraProtocolTitle(camera: any) {
  if (selectedDevice.value?.connection_type === 'HIKVISION') return 'HIKVISION';
  return camera.is_onvif ? 'ONVIF' : 'RTSP';
}

async function load() {
  const [devicesResponse, nodesResponse] = await Promise.all([
    api.get('/devices'),
    api.get('/dvr-servers')
  ]);
  devices.value = devicesResponse.data.items || [];
  nodes.value = nodesResponse.data.items || [];
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
    connection_type: device.connection_type || 'RTSP',
    archive_storage: device.archive_storage || 'node',
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

function openCameraCreate() {
  if (!selectedDevice.value) return;
  cameraEditingId.value = null;
  resetCameraForm();
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
    if (!cameraForm.name.trim() || !cameraForm.stream_name.trim()) {
      notify('Укажите название и stream name камеры', 'error');
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
      stream_name: cameraForm.stream_name,
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

    if (cameraEditingId.value) {
      await api.patch(`/cameras/${cameraEditingId.value}/config`, payload);
    } else {
      await api.post('/cameras', { ...payload, device_id: selectedDevice.value.id });
    }

    cameraDialog.value = false;
    notify(cameraEditingId.value ? 'Настройки камеры сохранены' : 'Камера создана');
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

async function discoverHikvisionChannels(mode: 'auto' | 'manual') {
  if (!selectedDevice.value) return;
  discoveringChannels.value = true;
  try {
    const { data } = await api.post(`/devices/${selectedDevice.value.id}/hikvision/channels/discover`, {
      mode,
      first_channel: manualFirstChannel.value,
      last_channel: manualLastChannel.value
    });
    discoveredChannels.value = data.items || [];
    channelsDialog.value = true;
    notify(discoveredChannels.value.length ? `Найдено каналов: ${discoveredChannels.value.length}` : 'Каналы не найдены', discoveredChannels.value.length ? 'success' : 'error');
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Не удалось найти каналы Hikvision', 'error');
  } finally {
    discoveringChannels.value = false;
  }
}

async function syncHikvisionChannels() {
  if (!selectedDevice.value) return;
  syncingChannels.value = true;
  try {
    const { data } = await api.post(`/devices/${selectedDevice.value.id}/hikvision/channels/sync`, {
      channels: discoveredChannels.value.filter((channel) => !channel.exists)
    });
    notify(`Создано камер: ${data.created?.length || 0}`);
    channelsDialog.value = false;
    await openView(selectedDevice.value);
    await load();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Не удалось создать камеры по каналам', 'error');
  } finally {
    syncingChannels.value = false;
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
    notify('Устройство сохранено; параметры node и архива применены ко всем его камерам');
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
