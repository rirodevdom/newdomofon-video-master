<template>
  <v-container fluid class="pa-6">
    <div class="d-flex align-center mb-4 flex-wrap ga-2">
      <h1 class="text-h4">Камеры</h1>
      <v-spacer />
      <v-text-field v-model="search" density="compact" label="Поиск" hide-details style="max-width: 280px" />
      <v-select v-model="enabledFilter" :items="enabledFilters" density="compact" label="Состояние" hide-details style="max-width: 180px" />
      <v-btn v-if="auth.isAdmin" color="primary" prepend-icon="mdi-devices" to="/devices">Настроить через устройства</v-btn>
    </div>

    <v-alert v-if="message" :type="messageType" variant="tonal" class="mb-4" closable @click:close="message = ''">{{ message }}</v-alert>

    <v-alert type="info" variant="tonal" class="mb-4">
      Камера является каналом устройства. Название, поток, протокол, node, место хранения архива и ONVIF/RTSP-параметры редактируются только внутри устройства. Здесь можно только включить или отключить камеру.
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
            <th>Включена</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="camera in filteredCameras" :key="camera.id">
            <td>{{ camera.name }}</td>
            <td><code>{{ camera.stream_name }}</code></td>
            <td><v-chip size="small" :color="protocolColor(camera)">{{ protocolTitle(camera) }}</v-chip></td>
            <td>{{ camera.device_name || '—' }}</td>
            <td>{{ camera.dvr_server_name || '—' }}</td>
            <td>{{ archiveStorageTitle(camera.device_archive_storage || camera.archive_storage) }}</td>
            <td>
              <v-chip size="small" :color="camera.is_enabled ? 'success' : 'error'">
                {{ camera.is_enabled ? 'Да' : 'Нет' }}
              </v-chip>
            </td>
            <td class="text-right" style="white-space: nowrap">
              <v-btn size="small" color="primary" variant="tonal" :to="`/cameras/${camera.id}`">Просмотр</v-btn>
              <v-btn v-if="auth.isAdmin" size="small" variant="tonal" class="ml-2" @click="openEnabledDialog(camera)">Изменить</v-btn>
              <v-btn v-if="auth.isAdmin && camera.device_id" size="small" variant="text" class="ml-2" to="/devices">Устройство</v-btn>
            </td>
          </tr>
          <tr v-if="!filteredCameras.length">
            <td colspan="8" class="text-center text-medium-emphasis py-6">Камеры не найдены</td>
          </tr>
        </tbody>
      </v-table>
    </v-card>

    <v-dialog v-model="dialog" max-width="520">
      <v-card>
        <v-card-title>Состояние камеры</v-card-title>
        <v-card-text>
          <div class="text-subtitle-1 mb-3">{{ selectedCamera?.name }}</div>
          <v-switch v-model="enabledValue" color="primary" label="Камера включена" />
          <v-alert type="info" variant="tonal" density="compact">
            Остальные параметры камеры изменяются в разделе «Устройства» внутри родительского устройства.
          </v-alert>
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn variant="tonal" @click="dialog = false">Отмена</v-btn>
          <v-btn color="primary" :loading="saving" @click="saveEnabled">Сохранить</v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>
  </v-container>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { api } from '../api';
import { useAuthStore } from '../stores/auth';

const auth = useAuthStore();
const cameras = ref<any[]>([]);
const search = ref('');
const enabledFilter = ref('all');
const enabledFilters = [
  { title: 'Все', value: 'all' },
  { title: 'Включённые', value: 'enabled' },
  { title: 'Отключённые', value: 'disabled' }
];
const message = ref('');
const messageType = ref<'success' | 'error'>('success');
const dialog = ref(false);
const saving = ref(false);
const selectedCamera = ref<any | null>(null);
const enabledValue = ref(true);

const filteredCameras = computed(() => {
  const needle = search.value.trim().toLowerCase();
  return cameras.value.filter((camera) => {
    const enabledOk = enabledFilter.value === 'all'
      || (enabledFilter.value === 'enabled' && camera.is_enabled)
      || (enabledFilter.value === 'disabled' && !camera.is_enabled);
    const textOk = !needle || [camera.name, camera.stream_name, camera.device_name, camera.dvr_server_name]
      .some((value) => String(value || '').toLowerCase().includes(needle));
    return enabledOk && textOk;
  });
});

function notify(text: string, type: 'success' | 'error' = 'success') {
  message.value = text;
  messageType.value = type;
}

function protocolTitle(camera: any) {
  if (camera.device_connection_type === 'HIKVISION') return 'HIKVISION';
  return camera.is_onvif ? 'ONVIF' : 'RTSP';
}

function protocolColor(camera: any) {
  if (camera.device_connection_type === 'HIKVISION') return 'deep-orange';
  return camera.is_onvif ? 'indigo' : 'blue';
}

function archiveStorageTitle(value: string) {
  if (value === 'device') return 'Устройство';
  if (value === 'both') return 'Node + устройство';
  return 'Node';
}

async function load() {
  cameras.value = (await api.get('/cameras')).data.items || [];
}

function openEnabledDialog(camera: any) {
  selectedCamera.value = camera;
  enabledValue.value = Boolean(camera.is_enabled);
  dialog.value = true;
}

async function saveEnabled() {
  if (!selectedCamera.value) return;
  saving.value = true;
  try {
    await api.patch(`/cameras/${selectedCamera.value.id}`, { is_enabled: enabledValue.value });
    dialog.value = false;
    notify(enabledValue.value ? 'Камера включена' : 'Камера отключена');
    await load();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Не удалось изменить состояние камеры', 'error');
  } finally {
    saving.value = false;
  }
}

onMounted(load);
</script>
