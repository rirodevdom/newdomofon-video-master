<template>
  <v-container fluid class="pa-6">
    <div class="d-flex align-center mb-4 flex-wrap ga-2">
      <h1 class="text-h4">Ноды</h1>
      <v-spacer />
      <v-text-field v-model="search" density="compact" label="Поиск" hide-details style="max-width: 280px" />
      <v-select v-model="statusFilter" :items="statusFilters" density="compact" label="Статус" hide-details style="max-width: 180px" />
      <v-btn v-if="auth.isAdmin" color="primary" prepend-icon="mdi-plus" @click="openCreate">Создать node</v-btn>
    </div>

    <v-alert type="info" variant="tonal" class="mb-4">
      Credentials создаются вручную при развёртывании node. При добавлении на master укажите те же
      <code>DVR_NODE_ID</code>, <code>DVR_NODE_TOKEN</code> и <code>DVR_NODE_MEDIA_SECRET</code>.
      Master больше не генерирует эти значения.
    </v-alert>

    <v-alert v-if="message" :type="messageType" variant="tonal" class="mb-4" closable @click:close="message = ''">{{ message }}</v-alert>

    <v-card>
      <v-table>
        <thead>
          <tr>
            <th>Название</th>
            <th>Статус</th>
            <th>Public URL</th>
            <th>Internal URL</th>
            <th>Камеры</th>
            <th>Устройства</th>
            <th>Диск</th>
            <th>Версия</th>
            <th>Last seen</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="node in filteredNodes" :key="node.id">
            <td>{{ node.name }}</td>
            <td><v-chip size="small" :color="nodeStatusColor(node)">{{ nodeHealth(node) }}</v-chip></td>
            <td class="text-truncate" style="max-width: 220px">{{ node.public_base_url || node.base_url || '—' }}</td>
            <td class="text-truncate" style="max-width: 220px">{{ node.internal_url || '—' }}</td>
            <td>{{ node.camera_count || 0 }}</td>
            <td>{{ node.device_count || 0 }}</td>
            <td>{{ storageLabel(node) }}</td>
            <td>{{ node.version || '—' }}</td>
            <td>{{ formatDate(node.last_seen_at) }}</td>
            <td class="text-right">
              <v-menu>
                <template #activator="{ props }">
                  <v-btn size="small" variant="tonal" v-bind="props">Действия</v-btn>
                </template>
                <v-list density="compact">
                  <v-list-item title="Перезагрузить конфиг" @click="sendCommand(node, 'reload_cameras')" />
                  <v-list-item title="Перезапустить записи" @click="sendCommand(node, 'restart_recordings')" />
                  <v-list-item title="Проверить подключение" @click="sendCommand(node, 'health_check')" />
                  <v-list-item v-if="auth.user?.role === 'super_admin'" title="Задать новые credentials" @click="openRotate(node)" />
                  <v-list-item title="Отключить node" @click="disable(node)" />
                  <v-list-item v-if="auth.user?.role === 'super_admin'" title="Удалить node" @click="remove(node)" />
                </v-list>
              </v-menu>
            </td>
          </tr>
          <tr v-if="!filteredNodes.length">
            <td colspan="10" class="text-center text-medium-emphasis py-6">Node не найдены</td>
          </tr>
        </tbody>
      </v-table>
    </v-card>

    <v-dialog v-model="dialog" max-width="900">
      <v-card>
        <v-card-title>Добавление заранее развёрнутой video node</v-card-title>
        <v-card-text>
          <v-alert type="warning" variant="tonal" class="mb-4">
            Скопируйте значения из <code>/root/newdomofon-node-master-registration.env</code> на node.
            Значения должны полностью совпадать с её <code>/etc/newdomofon-video/app.env</code>.
          </v-alert>
          <v-row>
            <v-col cols="12" md="6"><v-text-field v-model="form.name" label="Название node" /></v-col>
            <v-col cols="12" md="6"><v-switch v-model="form.is_enabled" color="primary" label="Активна" /></v-col>
            <v-col cols="12"><v-text-field :model-value="masterUrl" label="DVR_MASTER_URL (этот master)" readonly /></v-col>
            <v-col cols="12"><v-text-field v-model="form.node_id" label="DVR_NODE_ID" placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" autocomplete="off" /></v-col>
            <v-col cols="12"><v-text-field v-model="form.agent_token" label="DVR_NODE_TOKEN" type="password" autocomplete="new-password" /></v-col>
            <v-col cols="12"><v-text-field v-model="form.media_secret" label="DVR_NODE_MEDIA_SECRET" type="password" autocomplete="new-password" /></v-col>
            <v-col cols="12" md="6"><v-text-field v-model="form.public_base_url" label="DVR_NODE_PUBLIC_BASE_URL" placeholder="http://10.106.1.31" /></v-col>
            <v-col cols="12" md="6"><v-text-field v-model="form.internal_url" label="DVR_NODE_INTERNAL_URL" placeholder="http://10.106.1.31:3010" /></v-col>
          </v-row>
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn variant="tonal" @click="dialog = false">Отмена</v-btn>
          <v-btn color="primary" :loading="saving" :disabled="!canCreate" @click="createNode">Создать</v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>

    <v-dialog v-model="rotateDialog" max-width="720">
      <v-card>
        <v-card-title>Задать новые credentials</v-card-title>
        <v-card-text>
          <v-alert type="warning" variant="tonal" class="mb-4">
            Сначала внесите такие же новые значения в <code>/etc/newdomofon-video/app.env</code> на node,
            затем сохраните их здесь и перезапустите DVR-сервис node.
          </v-alert>
          <div class="mb-4 font-weight-medium">{{ rotationTarget?.name || '' }}</div>
          <v-text-field v-model="rotationForm.agent_token" label="Новый DVR_NODE_TOKEN" type="password" autocomplete="new-password" />
          <v-text-field v-model="rotationForm.media_secret" label="Новый DVR_NODE_MEDIA_SECRET" type="password" autocomplete="new-password" />
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn variant="tonal" @click="rotateDialog = false">Отмена</v-btn>
          <v-btn color="primary" :loading="rotating" :disabled="!canRotate" @click="rotateCredentials">Сохранить</v-btn>
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
const nodes = ref<any[]>([]);
const search = ref('');
const statusFilter = ref('all');
const statusFilters = ['all', 'online', 'warning', 'offline'];
const message = ref('');
const messageType = ref<'success' | 'error'>('success');
const dialog = ref(false);
const rotateDialog = ref(false);
const saving = ref(false);
const rotating = ref(false);
const rotationTarget = ref<any | null>(null);
const masterUrl = window.location.origin;

function blankCreateForm() {
  return {
    name: 'Node 1',
    node_id: '',
    agent_token: '',
    media_secret: '',
    public_base_url: '',
    internal_url: '',
    is_enabled: true
  };
}

const form = reactive(blankCreateForm());
const rotationForm = reactive({ agent_token: '', media_secret: '' });

const canCreate = computed(() => Boolean(
  form.name.trim() &&
  form.node_id.trim() &&
  form.agent_token.trim().length >= 16 &&
  form.media_secret.trim().length >= 16 &&
  form.public_base_url.trim() &&
  form.internal_url.trim()
));

const canRotate = computed(() => Boolean(
  rotationTarget.value &&
  rotationForm.agent_token.trim().length >= 16 &&
  rotationForm.media_secret.trim().length >= 16
));

const filteredNodes = computed(() => {
  const needle = search.value.trim().toLowerCase();
  return nodes.value.filter((node) => {
    const health = nodeHealth(node);
    const statusOk = statusFilter.value === 'all' || health === statusFilter.value;
    const textOk = !needle || [node.name, node.public_base_url, node.base_url, node.internal_url, health].some((value) => String(value || '').toLowerCase().includes(needle));
    return statusOk && textOk;
  });
});

function notify(text: string, type: 'success' | 'error' = 'success') {
  message.value = text;
  messageType.value = type;
}

function ageSeconds(value: string | null) {
  if (!value) return null;
  const age = Math.floor((Date.now() - new Date(value).getTime()) / 1000);
  return Number.isFinite(age) ? age : null;
}

function nodeHealth(node: any) {
  if (!node.is_enabled) return 'offline';
  const age = ageSeconds(node.last_seen_at);
  if (age === null) return 'offline';
  if (age < 60) return 'online';
  if (age < 180) return 'warning';
  return 'offline';
}

function nodeStatusColor(node: any) {
  const health = nodeHealth(node);
  if (health === 'online') return 'success';
  if (health === 'warning') return 'warning';
  return 'error';
}

function bytes(value: unknown) {
  const n = Number(value || 0);
  return Number.isFinite(n) ? n : 0;
}

function formatBytes(value: number) {
  if (!value) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${size.toFixed(size >= 10 || unit === 0 ? 0 : 1)} ${units[unit]}`;
}

function storageLabel(node: any) {
  const storage = node.storage || {};
  const total = bytes(storage.total_bytes || storage.total || storage.totalBytes);
  const free = bytes(storage.free_bytes || storage.available_bytes || storage.free || storage.available || storage.freeBytes);
  const used = bytes(storage.used_bytes || storage.used || storage.usedBytes) || (total && free ? Math.max(total - free, 0) : 0);
  return `${formatBytes(used)} / ${formatBytes(total)}`;
}

function formatDate(value: string | null) {
  return value ? new Date(value).toLocaleString() : '—';
}

async function load() {
  nodes.value = (await api.get('/dvr-servers')).data.items;
}

function openCreate() {
  Object.assign(form, blankCreateForm());
  dialog.value = true;
}

async function createNode() {
  saving.value = true;
  try {
    await api.post('/dvr-servers', {
      ...form,
      name: form.name.trim(),
      node_id: form.node_id.trim(),
      agent_token: form.agent_token.trim(),
      media_secret: form.media_secret.trim(),
      public_base_url: form.public_base_url.trim(),
      internal_url: form.internal_url.trim()
    });
    dialog.value = false;
    notify('Node создана с credentials, заданными при её развёртывании');
    Object.assign(form, blankCreateForm());
    await load();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка создания node', 'error');
  } finally {
    saving.value = false;
  }
}

async function sendCommand(node: any, type: string) {
  await api.post(`/dvr-servers/${node.id}/commands`, { type });
  notify(`Команда отправлена: ${type}`);
}

function openRotate(node: any) {
  rotationTarget.value = node;
  Object.assign(rotationForm, { agent_token: '', media_secret: '' });
  rotateDialog.value = true;
}

async function rotateCredentials() {
  if (!rotationTarget.value) return;
  rotating.value = true;
  try {
    await api.post(`/dvr-servers/${rotationTarget.value.id}/rotate-token`, {
      agent_token: rotationForm.agent_token.trim(),
      media_secret: rotationForm.media_secret.trim()
    });
    rotateDialog.value = false;
    notify('Новые credentials сохранены. Перезапустите DVR-сервис node с теми же значениями.');
    rotationTarget.value = null;
    Object.assign(rotationForm, { agent_token: '', media_secret: '' });
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка обновления credentials', 'error');
  } finally {
    rotating.value = false;
  }
}

async function disable(node: any) {
  await api.patch(`/dvr-servers/${node.id}`, { is_enabled: false });
  notify('Node отключена');
  await load();
}

async function remove(node: any) {
  if (!confirm(`Удалить node "${node.name}"?`)) return;
  await api.delete(`/dvr-servers/${node.id}`);
  notify('Node удалена');
  await load();
}

onMounted(load);
</script>
