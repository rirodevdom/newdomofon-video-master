<template>
  <v-container fluid class="pa-6">
    <div class="d-flex align-center mb-4 flex-wrap ga-2">
      <h1 class="text-h4">Устройства</h1>
      <v-spacer />
      <v-text-field v-model="search" density="compact" label="Поиск" hide-details style="max-width: 280px" />
      <v-select v-model="configuredFilter" :items="configuredFilters" density="compact" label="Настройка" hide-details style="max-width: 190px" />
      <v-btn v-if="auth.isAdmin" color="primary" prepend-icon="mdi-plus" @click="openCreateDevice">Добавить устройство</v-btn>
    </div>

    <v-alert v-if="message" :type="messageType" variant="tonal" class="mb-4" closable @click:close="message = ''">{{ message }}</v-alert>

    <v-alert type="info" variant="tonal" class="mb-4">
      Устройство определяет node и место хранения архива для всех своих камер. При изменении этих полей все камеры устройства автоматически переходят на новую политику записи. Статусы вручную не задаются.
    </v-alert>

    <v-card>
      <v-table>
        <thead>
          <tr>
            <th>Название</th>
            <th>Тип</th>
            <th>Node</th>
            <th>Архив</th>
            <th>Камер/каналов</th>
            <th>Настройка</th>
            <th>Включено</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="device in filteredDevices" :key="device.id" :class="{ 'bg-red-lighten-5': !device.is_configured }">
            <td>{{ device.name || '—' }}</td>
            <td><v-chip size="small" variant="tonal">{{ device.connection_type }}</v-chip></td>
            <td>{{ device.node_name || '—' }}</td>
            <td>{{ archiveStorageTitle(device.archive_storage) }}</td>
            <td>{{ device.camera_count }}</td>
            <td>
              <v-chip size="small" :color="device.is_configured ? 'success' : 'error'">
                {{ device.is_configured ? 'Настроено' : 'Не донастроено' }}
              </v-chip>
            </td>
            <td><v-chip size="small" :color="device.is_enabled ? 'success' : 'default'">{{ device.is_enabled ? 'Да' : 'Нет' }}</v-chip></td>
            <td class="text-right" style="white-space: nowrap">
              <v-btn size="small" color="primary" variant="tonal" @click="openDevice(device)">Камеры</v-btn>
              <v-btn v-if="auth.isAdmin" size="small" variant="tonal" class="ml-2" @click="openEditDevice(device)">Устройство</v-btn>
              <v-btn v-if="auth.user?.role === 'super_admin'" size="small" color="error" variant="text" class="ml-2" @click="removeDevice(device)">Удалить</v-btn>
            </td>
          </tr>
          <tr v-if="!filteredDevices.length">
            <td colspan="8" class="text-center text-medium-emphasis py-6">Устройства не найдены</td>
          </tr>
        </tbody>
      </v-table>
    </v-card>

    <v-dialog v-model="deviceDialog" max-width="900">
      <v-card>
        <v-card-title>{{ editingDeviceId ? 'Редактирование устройства' : 'Новое устройство' }}</v-card-title>
        <v-card-text>
          <v-row>
            <v-col cols="12" md="6"><v-text-field v-model="deviceForm.name" label="Название устройства" /></v-col>
            <v-col cols="12" md="3"><v-select v-model="deviceForm.connection_type" :items="connectionTypes" label="Тип подключения" /></v-col>
            <v-col cols="12" md="3"><v-switch v-model="deviceForm.is_enabled" color="primary" label="Включено" /></v-col>
            <v-col cols="12" md="6">
              <v-select v-model="deviceForm.dvr_server_id" :items="nodes" item-title="name" item-value="id" label="Node для всех камер" clearable />
            </v-col>
            <v-col cols="12" md="6">
              <v-select v-model="deviceForm.archive_storage" :items="archiveStorageItems" label="Где хранится архив всех камер" />
            </v-col>
            <v-col cols="12">
              <v-alert type="warning" variant="tonal" density="compact">
                Изменение Node или места архива применяется ко всем камерам этого устройства и отправляет reload старой и новой node.
              </v-alert>
            </v-col>
            <v-col cols="12" md="6"><v-text-field v-model="deviceForm.host" label="Host/IP" /></v-col>
            <v-col cols="12" md="2"><v-text-field v-model.number="deviceForm.port" label="Port" type="number" /></v-col>
            <v-col cols="12" md="4"><v-text-field v-model="deviceForm.username" label="Login" autocomplete="off" /></v-col>
            <v-col cols="12" md="6"><v-text-field v-model="deviceForm.password" label="Password" type="password" autocomplete="new-password" /></v-col>
            <v-col v-if="deviceForm.connection_type !== 'ONVIF'" cols="12" md="6">
              <v-text-field v-model="deviceForm.rtsp_url" label="Базовый RTSP URL" />
            </v-col>
            <v-col cols="12"><v-textarea v-model="deviceForm.comment" label="Комментарий" rows="2" /></v-col>
          </v-row>
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn variant="tonal" @click="deviceDialog = false">Отмена</v-btn>
          <v-btn color="primary" :loading="savingDevice" @click="saveDevice">Сохранить</v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>

    <v-dialog v-model="camerasDialog" max-width="1100">
      <v-card>
        <v-card-title>Камеры устройства: {{ selectedDevice?.name }}</v-card-title>
        <v-card-subtitle>
          Node: {{ selectedDevice?.node_name || 'не назначена' }} · Архив: {{ archiveStorageTitle(selectedDevice?.archive_storage) }}
        </v-card-subtitle>
        <v-card-text>
          <div class="d-flex justify-end mb-3 flex-wrap ga-2">
            <template v-if="selectedDevice?.connection_type === 'HIKVISION'">
              <v-btn color="deep-orange" variant="tonal" prepend-icon="mdi-magnify" :loading="discoveringChannels" @click="discoverHikvisionChannels('auto')">Авто-поиск каналов</v-btn>
              <v-text-field v-model.number="manualFirstChannel" density="compact" label="С" type="number" hide-details style="max-width: 90px" />
              <v-text-field v-model.number="manualLastChannel" density="compact" label="По" type="number" hide-details style="max-width: 90px" />
              <v-btn variant="tonal" :loading="discoveringChannels" @click="discoverHikvisionChannels('manual')">Найти диапазон</v-btn>
            </template>
            <v-btn v-if="auth.isAdmin" color="primary" prepend-icon="mdi-plus" @click="openCreateCamera">Добавить камеру</v-btn>
          </div>

          <v-table>
            <thead>
              <tr><th>Название</th><th>Поток</th><th>Протокол</th><th>Архив, дней</th><th>Включена</th><th></th></tr>
            </thead>
            <tbody>
              <tr v-for="camera in deviceCameras" :key="camera.id">
                <td>{{ camera.name }}</td>
                <td><code>{{ camera.stream_name }}</code></td>
                <td>{{ selectedDevice?.connection_type }}</td>
                <td>{{ camera.retention_days }}</td>
                <td><v-chip size="small" :color="camera.is_enabled ? 'success' : 'error'">{{ camera.is_enabled ? 'Да' : 'Нет' }}</v-chip></td>
                <td class="text-right" style="white-space: nowrap">
                  <v-btn size="small" :to="`/cameras/${camera.id}`">Просмотр</v-btn>
                  <v-btn v-if="auth.isAdmin" size="small" variant="tonal" class="ml-2" @click="openEditCamera(camera)">Настроить</v-btn>
                  <v-btn v-if="auth.user?.role === 'super_admin'" size="small" color="error" variant="text" class="ml-2" @click="removeCamera(camera)">Удалить</v-btn>
                </td>
              </tr>
              <tr v-if="!deviceCameras.length"><td colspan="6" class="text-center text-medium-emphasis py-6">Камеры не добавлены</td></tr>
            </tbody>
          </v-table>
        </v-card-text>
        <v-card-actions><v-spacer /><v-btn variant="tonal" @click="camerasDialog = false">Закрыть</v-btn></v-card-actions>
      </v-card>
    </v-dialog>

    <v-dialog v-model="cameraDialog" max-width="900">
      <v-card>
        <v-card-title>{{ editingCameraId ? 'Настройка камеры устройства' : 'Новая камера устройства' }}</v-card-title>
        <v-card-text>
          <v-alert type="info" variant="tonal" density="compact" class="mb-4">
            Устройство фиксировано: {{ selectedDevice?.name }}. Node и место архива наследуются от устройства и не могут быть изменены у отдельной камеры.
          </v-alert>
          <v-row>
            <v-col cols="12" md="6"><v-text-field v-model="cameraForm.name" label="Название камеры" /></v-col>
            <v-col cols="12" md="6"><v-text-field v-model="cameraForm.stream_name" label="Stream name" /></v-col>
            <v-col cols="12" md="4"><v-text-field :model-value="selectedDevice?.node_name || '—'" label="Node устройства" readonly /></v-col>
            <v-col cols="12" md="4"><v-text-field :model-value="archiveStorageTitle(selectedDevice?.archive_storage)" label="Архив устройства" readonly /></v-col>
            <v-col cols="12" md="4"><v-text-field v-model.number="cameraForm.retention_days" label="Архив, дней" type="number" /></v-col>
            <v-col cols="12" md="4"><v-switch v-model="cameraForm.is_enabled" color="primary" label="Включена" /></v-col>

            <template v-if="selectedDevice?.connection_type === 'ONVIF'">
              <v-col cols="12">
                <v-alert type="info" variant="tonal" density="compact">
                  ONVIF Host, port и credentials берутся из устройства. Нажмите получение URI после изменения параметров устройства.
                </v-alert>
              </v-col>
              <v-col cols="12" md="8"><v-text-field v-model="cameraForm.source_url" label="Полученный RTSP URI" readonly /></v-col>
              <v-col cols="12" md="4"><v-btn block color="indigo" variant="tonal" :loading="resolvingOnvif" @click="resolveOnvifStream">Получить RTSP URI</v-btn></v-col>
            </template>
            <template v-else>
              <v-col cols="12"><v-text-field v-model="cameraForm.source_url" label="RTSP URL камеры/канала" /></v-col>
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
          <v-alert v-if="!discoveredChannels.length" type="warning" variant="tonal">Каналы не найдены.</v-alert>
          <v-table v-else>
            <thead><tr><th>Канал</th><th>Track ID</th><th>Название</th><th>Online</th><th>Состояние</th><th>RTSP</th></tr></thead>
            <tbody>
              <tr v-for="channel in discoveredChannels" :key="channel.track_id">
                <td>{{ channel.channel }}</td><td><code>{{ channel.track_id }}</code></td><td>{{ channel.name }}</td>
                <td>{{ channel.online === true ? 'online' : channel.online === false ? 'offline' : 'unknown' }}</td>
                <td>{{ channel.exists ? 'уже есть' : 'будет создан' }}</td><td><code>{{ channel.source_url }}</code></td>
              </tr>
            </tbody>
          </v-table>
        </v-card-text>
        <v-card-actions><v-spacer /><v-btn variant="tonal" @click="channelsDialog = false">Закрыть</v-btn><v-btn color="primary" :disabled="!discoveredChannels.some((item) => !item.exists)" :loading="syncingChannels" @click="syncHikvisionChannels">Создать отсутствующие</v-btn></v-card-actions>
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
const selectedDevice = ref<any | null>(null);
const deviceCameras = ref<any[]>([]);
const search = ref('');
const configuredFilter = ref('all');
const configuredFilters = [
  { title: 'Все', value: 'all' },
  { title: 'Настроенные', value: 'configured' },
  { title: 'Не донастроенные', value: 'unconfigured' }
];
const message = ref('');
const messageType = ref<'success' | 'error'>('success');
const deviceDialog = ref(false);
const camerasDialog = ref(false);
const cameraDialog = ref(false);
const channelsDialog = ref(false);
const savingDevice = ref(false);
const savingCamera = ref(false);
const resolvingOnvif = ref(false);
const discoveringChannels = ref(false);
const syncingChannels = ref(false);
const editingDeviceId = ref<string | null>(null);
const editingCameraId = ref<string | null>(null);
const discoveredChannels = ref<any[]>([]);
const manualFirstChannel = ref(1);
const manualLastChannel = ref(16);
const connectionTypes = ['RTSP', 'ONVIF', 'HIKVISION'];
const archiveStorageItems = [
  { title: 'На video node', value: 'node' },
  { title: 'На устройстве Hikvision/NVR', value: 'device' },
  { title: 'Node + устройство', value: 'both' }
];

const deviceForm = reactive<any>({
  name: '', connection_type: 'RTSP', archive_storage: 'node', dvr_server_id: null,
  host: '', port: null, username: '', password: '', rtsp_url: '', comment: '', is_enabled: true
});
const cameraForm = reactive<any>({
  name: '', stream_name: '', source_url: '', retention_days: 7, is_enabled: true,
  group_id: null, onvif_xaddr: null, onvif_port: null, onvif_username: null,
  onvif_password: null, onvif_profile_token: null, onvif_device_info: null, onvif_last_sync_at: null
});

const filteredDevices = computed(() => {
  const needle = search.value.trim().toLowerCase();
  return devices.value.filter((device) => {
    const configuredOk = configuredFilter.value === 'all'
      || (configuredFilter.value === 'configured' && device.is_configured)
      || (configuredFilter.value === 'unconfigured' && !device.is_configured);
    const textOk = !needle || [device.name, device.connection_type, device.node_name, device.host, device.rtsp_url]
      .some((value) => String(value || '').toLowerCase().includes(needle));
    return configuredOk && textOk;
  });
});

function notify(text: string, type: 'success' | 'error' = 'success') { message.value = text; messageType.value = type; }
function archiveStorageTitle(value: string) { return value === 'device' ? 'Устройство' : value === 'both' ? 'Node + устройство' : 'Node'; }
function resetDeviceForm() { Object.assign(deviceForm, { name: '', connection_type: 'RTSP', archive_storage: 'node', dvr_server_id: null, host: '', port: null, username: '', password: '', rtsp_url: '', comment: '', is_enabled: true }); }
function resetCameraForm() { Object.assign(cameraForm, { name: '', stream_name: '', source_url: '', retention_days: 7, is_enabled: true, group_id: null, onvif_xaddr: null, onvif_port: null, onvif_username: null, onvif_password: null, onvif_profile_token: null, onvif_device_info: null, onvif_last_sync_at: null }); }

async function load() {
  const [deviceResponse, nodeResponse] = await Promise.all([api.get('/devices'), api.get('/dvr-servers')]);
  devices.value = deviceResponse.data.items || [];
  nodes.value = nodeResponse.data.items || [];
}

function openCreateDevice() { editingDeviceId.value = null; resetDeviceForm(); deviceDialog.value = true; }
function openEditDevice(device: any) { editingDeviceId.value = device.id; Object.assign(deviceForm, { ...device, password: '' }); deviceDialog.value = true; }

async function saveDevice() {
  savingDevice.value = true;
  try {
    const payload = { ...deviceForm };
    delete payload.status;
    delete payload.last_check_at;
    delete payload.node_name;
    delete payload.camera_count;
    delete payload.is_configured;
    delete payload.created_at;
    delete payload.updated_at;
    delete payload.id;
    if (!payload.password) delete payload.password;
    if (editingDeviceId.value) await api.patch(`/devices/${editingDeviceId.value}`, payload);
    else await api.post('/devices', payload);
    deviceDialog.value = false;
    notify('Устройство сохранено. Политика Node/архива применена к его камерам.');
    await load();
    if (selectedDevice.value?.id === editingDeviceId.value) await openDevice({ id: editingDeviceId.value });
  } catch (err: any) { notify(err.response?.data?.error || err.message || 'Ошибка сохранения устройства', 'error'); }
  finally { savingDevice.value = false; }
}

async function openDevice(device: any) {
  const { data } = await api.get(`/devices/${device.id}`);
  selectedDevice.value = data.item;
  deviceCameras.value = data.cameras || [];
  camerasDialog.value = true;
}

function openCreateCamera() {
  editingCameraId.value = null;
  resetCameraForm();
  if (selectedDevice.value?.connection_type !== 'ONVIF') cameraForm.source_url = selectedDevice.value?.rtsp_url || '';
  cameraDialog.value = true;
}

async function openEditCamera(camera: any) {
  editingCameraId.value = camera.id;
  const { data } = await api.get(`/cameras/${camera.id}`);
  const item = data.item;
  Object.assign(cameraForm, {
    name: item.name, stream_name: item.stream_name, source_url: item.source_url,
    retention_days: item.retention_days, is_enabled: item.is_enabled, group_id: item.group_id,
    onvif_xaddr: item.onvif_xaddr, onvif_port: item.onvif_port,
    onvif_username: item.onvif_username, onvif_password: null,
    onvif_profile_token: item.onvif_profile_token, onvif_device_info: item.onvif_device_info,
    onvif_last_sync_at: item.onvif_last_sync_at
  });
  cameraDialog.value = true;
}

async function resolveOnvifStream() {
  if (!selectedDevice.value) return;
  resolvingOnvif.value = true;
  try {
    const body = editingCameraId.value
      ? { camera_id: editingCameraId.value }
      : {
          ip: selectedDevice.value.host,
          port: selectedDevice.value.port || 80,
          username: selectedDevice.value.username || undefined,
          dvr_server_id: selectedDevice.value.dvr_server_id || undefined
        };
    const { data } = await api.post('/onvif/stream-uri', body);
    cameraForm.source_url = data.streamUri || '';
    cameraForm.onvif_xaddr = data.xaddr || `http://${selectedDevice.value.host}:${selectedDevice.value.port || 80}/onvif/device_service`;
    cameraForm.onvif_port = selectedDevice.value.port || 80;
    cameraForm.onvif_username = selectedDevice.value.username || null;
    cameraForm.onvif_profile_token = data.selectedProfileToken || null;
    cameraForm.onvif_device_info = data.information || null;
    cameraForm.onvif_last_sync_at = new Date().toISOString();
    notify('ONVIF RTSP URI получен');
  } catch (err: any) { notify(err.response?.data?.error || err.message || 'Не удалось получить ONVIF URI', 'error'); }
  finally { resolvingOnvif.value = false; }
}

async function saveCamera() {
  if (!selectedDevice.value) return;
  savingCamera.value = true;
  try {
    if (!cameraForm.name || !cameraForm.stream_name || !cameraForm.source_url) throw new Error('Заполните название, stream name и RTSP URI');
    const configPayload: any = { ...cameraForm };
    delete configPayload.is_enabled;
    if (selectedDevice.value.connection_type !== 'ONVIF') {
      Object.assign(configPayload, { onvif_xaddr: null, onvif_port: null, onvif_username: null, onvif_password: null, onvif_profile_token: null, onvif_device_info: null, onvif_last_sync_at: null });
    } else {
      configPayload._onvif_requery = true;
      if (!configPayload.onvif_password) delete configPayload.onvif_password;
    }

    if (editingCameraId.value) {
      await api.patch(`/cameras/${editingCameraId.value}/config`, configPayload);
      const current = deviceCameras.value.find((camera) => camera.id === editingCameraId.value);
      if (!current || Boolean(current.is_enabled) !== Boolean(cameraForm.is_enabled)) {
        await api.patch(`/cameras/${editingCameraId.value}`, { is_enabled: cameraForm.is_enabled });
      }
    } else {
      await api.post('/cameras', { ...configPayload, device_id: selectedDevice.value.id, is_enabled: cameraForm.is_enabled });
    }
    cameraDialog.value = false;
    notify('Камера устройства сохранена');
    await openDevice(selectedDevice.value);
    await load();
  } catch (err: any) { notify(err.response?.data?.error || err.message || 'Ошибка сохранения камеры', 'error'); }
  finally { savingCamera.value = false; }
}

async function removeCamera(camera: any) {
  if (!confirm(`Удалить камеру «${camera.name}»?`)) return;
  await api.delete(`/cameras/${camera.id}`);
  notify('Камера удалена');
  await openDevice(selectedDevice.value);
  await load();
}

async function removeDevice(device: any) {
  if (!confirm(`Удалить устройство «${device.name}» и все его камеры?`)) return;
  await api.delete(`/devices/${device.id}`);
  notify('Устройство удалено');
  await load();
}

async function discoverHikvisionChannels(mode: 'auto' | 'manual') {
  if (!selectedDevice.value) return;
  discoveringChannels.value = true;
  try {
    const { data } = await api.post(`/devices/${selectedDevice.value.id}/hikvision/channels/discover`, { mode, first_channel: manualFirstChannel.value, last_channel: manualLastChannel.value });
    discoveredChannels.value = data.items || [];
    channelsDialog.value = true;
  } catch (err: any) { notify(err.response?.data?.error || err.message || 'Не удалось найти каналы', 'error'); }
  finally { discoveringChannels.value = false; }
}

async function syncHikvisionChannels() {
  if (!selectedDevice.value) return;
  syncingChannels.value = true;
  try {
    const { data } = await api.post(`/devices/${selectedDevice.value.id}/hikvision/channels/sync`, { channels: discoveredChannels.value.filter((item) => !item.exists) });
    notify(`Создано камер: ${data.created?.length || 0}`);
    channelsDialog.value = false;
    await openDevice(selectedDevice.value);
    await load();
  } catch (err: any) { notify(err.response?.data?.error || err.message || 'Не удалось создать каналы', 'error'); }
  finally { syncingChannels.value = false; }
}

onMounted(load);
</script>
