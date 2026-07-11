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
      В списке камер можно только включить или отключить камеру.
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
            <th>Live URL</th>
            <th>Archive URL</th>
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
            <td><code>{{ liveUrl(camera) }}</code></td>
            <td><code>{{ archiveUrl(camera) }}</code></td>
            <td class="text-right" style="white-space: nowrap">
              <v-btn size="small" color="primary" variant="tonal" :to="`/cameras/${camera.id}`">Просмотр</v-btn>
              <v-btn v-if="auth.isAdmin" size="small" variant="tonal" class="ml-2" @click="openEdit(camera)">
                Включение
              </v-btn>
            </td>
          </tr>
          <tr v-if="!filteredCameras.length">
            <td colspan="11" class="text-center text-medium-emphasis py-6">Камеры не найдены</td>
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
  </v-container>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import { api } from '../api';
import { useAuthStore } from '../stores/auth';

const auth = useAuthStore();
const cameras = ref<any[]>([]);
const search = ref('');
const message = ref('');
const messageType = ref<'success' | 'error'>('success');
const dialog = ref(false);
const saving = ref(false);
const editingCamera = ref<any | null>(null);
const form = reactive({ is_enabled: true });

const filteredCameras = computed(() => {
  const needle = search.value.trim().toLowerCase();
  if (!needle) return cameras.value;
  return cameras.value.filter((camera) =>
    [camera.name, camera.stream_name, camera.device_name, camera.dvr_server_name]
      .some((value) => String(value || '').toLowerCase().includes(needle))
  );
});

function liveUrl(camera: any) {
  return `/cameras/${camera.stream_name}/live.m3u8`;
}

function archiveUrl(camera: any) {
  return `/cameras/${camera.stream_name}/archive.m3u8`;
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

function notify(text: string, type: 'success' | 'error' = 'success') {
  message.value = text;
  messageType.value = type;
}

async function load() {
  cameras.value = (await api.get('/cameras')).data.items || [];
}

function openEdit(camera: any) {
  editingCamera.value = camera;
  form.is_enabled = Boolean(camera.is_enabled);
  dialog.value = true;
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

onMounted(load);
</script>
