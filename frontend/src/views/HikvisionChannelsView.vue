<template>
  <v-container fluid class="pa-6">
    <div class="d-flex align-center mb-4 flex-wrap ga-2">
      <div>
        <h1 class="text-h4">Hikvision-каналы</h1>
        <div class="text-medium-emphasis">Live и архив каналов, обнаруженных специализированными Hikvision-node</div>
      </div>
      <v-spacer />
      <v-text-field v-model="search" density="compact" label="Поиск" hide-details style="max-width: 280px" />
      <v-btn prepend-icon="mdi-refresh" :loading="loading" @click="load">Обновить</v-btn>
    </div>

    <v-alert v-if="error" type="error" variant="tonal" class="mb-4" closable @click:close="error = ''">
      {{ error }}
    </v-alert>

    <v-card>
      <v-table>
        <thead>
          <tr>
            <th>Устройство</th>
            <th>Канал</th>
            <th>Название</th>
            <th>Статус</th>
            <th>Поток</th>
            <th>Профили</th>
            <th>Архив</th>
            <th>Node</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="channel in filteredChannels" :key="channel.id">
            <td>{{ channel.device_name }}</td>
            <td>{{ channel.physical_channel }}</td>
            <td>{{ channel.name || channel.id }}</td>
            <td>
              <v-chip size="small" :color="channel.online === true ? 'success' : channel.online === false ? 'error' : 'warning'">
                {{ channel.online === true ? 'online' : channel.online === false ? 'offline' : 'unknown' }}
              </v-chip>
            </td>
            <td><code>{{ channel.primary_stream_id }}</code></td>
            <td>{{ Array.isArray(channel.streams) ? channel.streams.length : 0 }}</td>
            <td>{{ channel.archive_storage === 'device' ? 'Hikvision/NVR' : 'Hikvision-node' }} · {{ channel.retention_days }} дн.</td>
            <td>{{ channel.node_name || '—' }}</td>
            <td class="text-right">
              <v-btn
                size="small"
                color="primary"
                variant="tonal"
                prepend-icon="mdi-play-circle"
                :disabled="channel.online === false || !channel.enabled"
                :to="`/hikvision/${encodeURIComponent(channel.id)}`"
              >
                Просмотр
              </v-btn>
            </td>
          </tr>
          <tr v-if="!filteredChannels.length">
            <td colspan="9" class="text-center text-medium-emphasis py-6">
              {{ loading ? 'Загрузка каналов...' : 'Hikvision-каналы не найдены' }}
            </td>
          </tr>
        </tbody>
      </v-table>
    </v-card>
  </v-container>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { api } from '../api';

const channels = ref<any[]>([]);
const search = ref('');
const loading = ref(false);
const error = ref('');

const filteredChannels = computed(() => {
  const needle = search.value.trim().toLowerCase();
  if (!needle) return channels.value;
  return channels.value.filter((channel) => [
    channel.device_name,
    channel.name,
    channel.id,
    channel.primary_stream_id,
    channel.node_name,
    channel.archive_storage
  ].some((value) => String(value || '').toLowerCase().includes(needle)));
});

async function load() {
  loading.value = true;
  error.value = '';
  try {
    const devicesResponse = await api.get('/devices');
    const devices = (devicesResponse.data.items || []).filter((device: any) => device.connection_type === 'HIKVISION');
    const details = await Promise.all(devices.map((device: any) => api.get(`/devices/${encodeURIComponent(device.id)}`)));
    channels.value = details.flatMap((response: any) => {
      const device = response.data.item;
      return (response.data.hikvision_channels || []).map((channel: any) => ({
        ...channel,
        device_id: device.id,
        device_name: device.name,
        node_name: device.node_name
      }));
    }).sort((left: any, right: any) =>
      String(left.device_name).localeCompare(String(right.device_name), 'ru')
      || Number(left.physical_channel) - Number(right.physical_channel)
    );
  } catch (err: any) {
    error.value = err.response?.data?.error || err.message || 'Не удалось загрузить Hikvision-каналы';
  } finally {
    loading.value = false;
  }
}

onMounted(() => { void load(); });
</script>
