<template>
  <v-container fluid class="pa-6">
    <h1 class="text-h4 mb-4">Администрирование</h1>

    <v-tabs v-model="tab">
      <v-tab value="users">Пользователи</v-tab>
      <v-tab value="tokens">Токены</v-tab>
    </v-tabs>

    <v-alert v-if="message" :type="messageType" variant="tonal" class="my-4" closable @click:close="message = ''">{{ message }}</v-alert>

    <v-window v-model="tab" class="mt-4">
      <v-window-item value="users">
        <v-card class="pa-4 mb-4">
          <v-card-title>Создать пользователя</v-card-title>
          <v-row>
            <v-col cols="12" md="3"><v-text-field v-model="userForm.login" label="Логин" /></v-col>
            <v-col cols="12" md="3"><v-text-field v-model="userForm.password" label="Пароль" type="password" /></v-col>
            <v-col cols="12" md="3"><v-select v-model="userForm.role" :items="roles" label="Роль" /></v-col>
            <v-col cols="12" md="3"><v-switch v-model="userForm.is_active" color="primary" label="Активен" /></v-col>
          </v-row>
          <v-btn color="primary" :loading="savingUser" @click="createUser">Создать</v-btn>
        </v-card>

        <v-card>
          <v-table>
            <thead><tr><th>Логин</th><th>Роль</th><th>Активен</th><th>Создан</th><th></th></tr></thead>
            <tbody>
              <tr v-for="user in users" :key="user.id">
                <td>{{ user.login }}</td>
                <td>
                  <v-select v-model="user.role" :items="roles" density="compact" hide-details style="max-width: 180px" @update:model-value="patchUser(user, { role: user.role })" />
                </td>
                <td>
                  <v-switch v-model="user.is_active" color="primary" density="compact" hide-details @update:model-value="patchUser(user, { is_active: user.is_active })" />
                </td>
                <td>{{ formatDate(user.created_at) }}</td>
                <td class="text-right">
                  <v-btn size="small" variant="tonal" @click="openPasswordReset(user)">Сброс пароля</v-btn>
                  <v-btn size="small" color="error" variant="tonal" class="ml-2" @click="removeUser(user)">Удалить</v-btn>
                </td>
              </tr>
              <tr v-if="!users.length">
                <td colspan="5" class="text-center text-medium-emphasis py-6">Пользователи не найдены</td>
              </tr>
            </tbody>
          </v-table>
        </v-card>
      </v-window-item>

      <v-window-item value="tokens">
        <v-row>
          <v-col cols="12" md="6">
            <v-card>
              <v-card-title>Системные токены</v-card-title>
              <v-table>
                <thead><tr><th>Тип</th><th>Статус</th><th>Последнее использование</th></tr></thead>
                <tbody>
                  <tr>
                    <td>Node registration token</td>
                    <td><v-chip size="small" :color="tokens.node_registration_token?.configured ? 'success' : 'error'">{{ tokens.node_registration_token?.configured ? 'configured' : 'missing' }}</v-chip></td>
                    <td>{{ formatOptionalDate(tokens.node_registration_token?.last_used_at) }}</td>
                  </tr>
                  <tr>
                    <td>Internal DVR secret</td>
                    <td><v-chip size="small" :color="tokens.internal_dvr_secret?.configured ? 'success' : 'error'">{{ tokens.internal_dvr_secret?.configured ? 'configured' : 'missing' }}</v-chip></td>
                    <td>{{ formatOptionalDate(tokens.internal_dvr_secret?.last_used_at) }}</td>
                  </tr>
                </tbody>
              </v-table>
            </v-card>
          </v-col>
          <v-col cols="12" md="6">
            <v-alert type="info" variant="tonal">
              Системные секреты не показываются после создания. Управляемые токены камер создаются отдельно ниже и выбираются при открытии ссылок.
            </v-alert>
          </v-col>
        </v-row>

        <v-card class="mt-4">
          <v-card-title>Node agent/media tokens</v-card-title>
          <v-table>
            <thead><tr><th>Node</th><th>Agent token</th><th>Media secret</th><th>Создан</th><th>Последнее использование</th><th></th></tr></thead>
            <tbody>
              <tr v-for="node in tokens.node_tokens || []" :key="node.id">
                <td>{{ node.name }}</td>
                <td><v-chip size="small" :color="node.has_agent_token ? 'success' : 'error'">{{ node.has_agent_token ? 'configured' : 'missing' }}</v-chip></td>
                <td><v-chip size="small" :color="node.has_media_secret ? 'success' : 'error'">{{ node.has_media_secret ? 'configured' : 'missing' }}</v-chip></td>
                <td>{{ formatDate(node.created_at) }}</td>
                <td>{{ formatOptionalDate(node.last_used_at) }}</td>
                <td class="text-right"><v-btn size="small" variant="tonal" @click="rotateNodeToken(node)">Ротировать</v-btn></td>
              </tr>
            </tbody>
          </v-table>
        </v-card>

        <v-card class="mt-4 pa-4">
          <v-card-title class="px-0">Создать управляемый токен камер</v-card-title>
          <v-row>
            <v-col cols="12" md="3">
              <v-text-field v-model="managedTokenForm.name" label="Название токена" placeholder="SmartYard Иваново" />
            </v-col>
            <v-col cols="12" md="4">
              <v-text-field v-model="managedTokenForm.description" label="Описание" placeholder="Для интеграции или клиента" />
            </v-col>
            <v-col cols="12" md="3">
              <v-text-field v-model="managedTokenForm.expires_at" type="datetime-local" label="Истекает (необязательно)" />
            </v-col>
            <v-col cols="6" md="1">
              <v-switch v-model="managedTokenForm.allow_camera" color="primary" label="Видео" hide-details />
            </v-col>
            <v-col cols="6" md="1">
              <v-switch v-model="managedTokenForm.allow_events" color="primary" label="События" hide-details />
            </v-col>
          </v-row>
          <v-btn
            color="primary"
            :loading="creatingManagedToken"
            :disabled="!managedTokenForm.name.trim() || (!managedTokenForm.allow_camera && !managedTokenForm.allow_events)"
            @click="createManagedToken"
          >
            Создать токен
          </v-btn>
        </v-card>

        <v-alert v-if="createdManagedToken" type="warning" variant="tonal" class="mt-4">
          <div class="font-weight-bold mb-2">Токен создан или ротирован. Старые ссылки после ротации перестают работать.</div>
          <v-textarea :model-value="createdManagedToken.token" label="Значение токена" rows="2" readonly density="compact" />
          <v-btn size="small" color="primary" variant="tonal" @click="copyText(createdManagedToken.token)">Копировать токен</v-btn>
        </v-alert>

        <v-card class="mt-4">
          <v-card-title>Управляемые токены камер</v-card-title>
          <v-table>
            <thead>
              <tr>
                <th>Название</th>
                <th>Права</th>
                <th>Статус</th>
                <th>Камеры</th>
                <th>Истекает</th>
                <th>Последнее использование</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="token in managedTokens" :key="token.id">
                <td>
                  <div class="font-weight-medium">{{ token.name }}</div>
                  <div v-if="token.description" class="text-caption text-medium-emphasis">{{ token.description }}</div>
                </td>
                <td>
                  <v-chip v-for="scope in token.scopes" :key="scope" size="x-small" class="mr-1" variant="tonal">
                    {{ scope === 'camera' ? 'Видео' : 'События' }}
                  </v-chip>
                </td>
                <td>
                  <v-chip size="small" :color="managedTokenStatus(token).color">{{ managedTokenStatus(token).text }}</v-chip>
                </td>
                <td>
                  <span>{{ token.assigned_cameras?.length || 0 }}</span>
                  <div v-if="token.assigned_cameras?.length" class="text-caption text-medium-emphasis">
                    {{ token.assigned_cameras.map((camera: any) => camera.name).join(', ') }}
                  </div>
                </td>
                <td>{{ formatDate(token.expires_at) }}</td>
                <td>{{ formatOptionalDate(token.last_used_at) }}</td>
                <td class="text-right" style="white-space: nowrap">
                  <v-btn size="small" variant="text" icon="mdi-content-copy" title="Копировать" @click="copyText(token.token)" />
                  <v-btn size="small" variant="text" icon="mdi-refresh" title="Ротировать" @click="rotateManagedToken(token)" />
                  <v-btn
                    size="small"
                    variant="text"
                    :icon="token.is_active ? 'mdi-pause-circle-outline' : 'mdi-play-circle-outline'"
                    :title="token.is_active ? 'Отключить' : 'Включить'"
                    @click="toggleManagedToken(token)"
                  />
                  <v-btn size="small" color="error" variant="text" icon="mdi-delete-outline" title="Удалить" @click="removeManagedToken(token)" />
                </td>
              </tr>
              <tr v-if="!managedTokens.length">
                <td colspan="7" class="text-center text-medium-emphasis py-6">Управляемые токены ещё не созданы</td>
              </tr>
            </tbody>
          </v-table>
        </v-card>

        <v-card class="mt-4">
          <v-card-title>Ссылки камер</v-card-title>
          <v-card-subtitle class="pb-3">
            Выберите заранее созданный токен. Кнопка только привяжет его к камере и покажет ссылки — новый токен не создаётся.
          </v-card-subtitle>
          <v-table>
            <thead>
              <tr>
                <th>Камера</th>
                <th>Stream</th>
                <th>Node</th>
                <th>Режим</th>
                <th style="min-width: 260px">Токен</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <template v-for="camera in tokens.camera_links || []" :key="camera.id">
                <tr>
                  <td>{{ camera.name }}</td>
                  <td><code>{{ camera.stream_name }}</code></td>
                  <td>{{ camera.node_name || 'master' }}</td>
                  <td><v-chip size="small" color="primary" variant="tonal">managed-token</v-chip></td>
                  <td>
                    <v-select
                      v-model="cameraTokenSelection[camera.id]"
                      :items="availableManagedTokens"
                      item-title="name"
                      item-value="id"
                      density="compact"
                      hide-details
                      clearable
                      placeholder="Выберите токен"
                    >
                      <template #item="{ props, item }">
                        <v-list-item v-bind="props" :subtitle="tokenOptionSubtitle(item.raw)" />
                      </template>
                    </v-select>
                  </td>
                  <td class="text-right">
                    <v-btn
                      size="small"
                      variant="tonal"
                      :disabled="!cameraTokenSelection[camera.id]"
                      :loading="openingCameraLinks === camera.id"
                      @click="openCameraLinks(camera)"
                    >
                      Открыть ссылки
                    </v-btn>
                  </td>
                </tr>
                <tr v-if="generatedCameraLinks[camera.id]">
                  <td colspan="6" class="pb-4">
                    <v-alert type="info" variant="tonal" density="compact" class="mb-2">
                      Используется токен «{{ generatedCameraLinks[camera.id].managed_token?.name }}».
                      Срок действия: {{ formatDate(generatedCameraLinks[camera.id].expires_at) }}.
                    </v-alert>
                    <v-textarea :model-value="generatedCameraLinks[camera.id].smartyard_url" label="Общая ссылка для SmartYard-Server" rows="2" readonly density="compact" />
                    <v-textarea :model-value="generatedCameraLinks[camera.id].live_url" label="Live HLS URL" rows="2" readonly density="compact" />
                    <v-textarea :model-value="generatedCameraLinks[camera.id].archive_url_template" label="Archive HLS URL template" rows="2" readonly density="compact" />
                    <v-textarea :model-value="generatedCameraLinks[camera.id].events_url_template" label="Events URL template" rows="2" readonly density="compact" />
                    <div class="d-flex flex-wrap" style="gap: 8px">
                      <v-btn size="small" color="primary" variant="tonal" @click="copyText(generatedCameraLinks[camera.id].smartyard_url)">Копировать SmartYard</v-btn>
                      <v-btn size="small" variant="tonal" @click="copyText(generatedCameraLinks[camera.id].live_url)">Копировать live</v-btn>
                      <v-btn size="small" variant="tonal" @click="copyText(generatedCameraLinks[camera.id].archive_url_template)">Копировать archive</v-btn>
                      <v-btn size="small" variant="tonal" @click="copyText(generatedCameraLinks[camera.id].events_url_template)">Копировать events</v-btn>
                      <v-btn size="small" variant="tonal" @click="copyText(generatedCameraLinks[camera.id].camera_token)">Копировать token</v-btn>
                    </div>
                  </td>
                </tr>
              </template>
              <tr v-if="!(tokens.camera_links || []).length">
                <td colspan="6" class="text-center text-medium-emphasis py-6">Камеры не найдены</td>
              </tr>
            </tbody>
          </v-table>
        </v-card>

        <v-alert v-if="rotatedToken" type="warning" variant="tonal" class="mt-4">
          <div class="font-weight-bold mb-2">Новые значения Node показаны один раз.</div>
          <pre>{{ rotatedTokenText }}</pre>
        </v-alert>
      </v-window-item>
    </v-window>

    <v-dialog v-model="passwordDialog" max-width="520">
      <v-card>
        <v-card-title>Сброс пароля: {{ selectedUser?.login }}</v-card-title>
        <v-card-text><v-text-field v-model="newPassword" label="Новый пароль" type="password" /></v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn variant="tonal" @click="passwordDialog = false">Отмена</v-btn>
          <v-btn color="primary" @click="resetPassword">Сохранить</v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>
  </v-container>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import { api } from '../api';

const tab = ref('users');
const roles = ['super_admin', 'operator', 'viewer', 'installer'];
const users = ref<any[]>([]);
const tokens = ref<any>({});
const managedTokens = ref<any[]>([]);
const message = ref('');
const messageType = ref<'success' | 'error'>('success');
const savingUser = ref(false);
const passwordDialog = ref(false);
const selectedUser = ref<any | null>(null);
const newPassword = ref('');
const rotatedToken = ref<any | null>(null);
const createdManagedToken = ref<any | null>(null);
const creatingManagedToken = ref(false);
const generatedCameraLinks = ref<Record<string, any>>({});
const openingCameraLinks = ref<string | null>(null);
const cameraTokenSelection = reactive<Record<string, string | null>>({});

const managedTokenForm = reactive({
  name: '',
  description: '',
  expires_at: '',
  allow_camera: true,
  allow_events: true
});

const userForm = reactive({
  login: '',
  password: '',
  role: 'viewer',
  is_active: true,
  group_ids: []
});

const availableManagedTokens = computed(() => managedTokens.value.filter((token) => {
  if (!token.is_active || !token.scopes?.includes('camera')) return false;
  return !token.expires_at || new Date(token.expires_at).getTime() > Date.now();
}));

const rotatedTokenText = computed(() => {
  if (!rotatedToken.value) return '';
  return [
    `DVR_NODE_ID=${rotatedToken.value.node_id || rotatedToken.value.id}`,
    `DVR_NODE_TOKEN=${rotatedToken.value.agent_token || ''}`,
    rotatedToken.value.media_secret ? `DVR_NODE_MEDIA_SECRET=${rotatedToken.value.media_secret}` : ''
  ].filter(Boolean).join('\n');
});

function notify(text: string, type: 'success' | 'error' = 'success') {
  message.value = text;
  messageType.value = type;
}

function formatDate(value: string | null | undefined) {
  return value ? new Date(value).toLocaleString() : 'не истекает';
}

function formatOptionalDate(value: string | null | undefined) {
  return value ? new Date(value).toLocaleString() : '—';
}

function managedTokenStatus(token: any) {
  if (!token.is_active) return { text: 'отключён', color: 'error' };
  if (token.expires_at && new Date(token.expires_at).getTime() <= Date.now()) return { text: 'истёк', color: 'warning' };
  return { text: 'активен', color: 'success' };
}

function tokenOptionSubtitle(token: any) {
  const cameras = token.assigned_cameras?.length || 0;
  const expiry = token.expires_at ? new Date(token.expires_at).toLocaleString() : 'без срока';
  return `${cameras} камер · ${expiry}`;
}

async function loadUsers() {
  users.value = (await api.get('/users')).data.items;
}

async function loadTokens() {
  const [systemResponse, managedResponse] = await Promise.all([
    api.get('/tokens'),
    api.get('/tokens/managed-camera-tokens')
  ]);
  tokens.value = systemResponse.data;
  managedTokens.value = managedResponse.data.items || [];
}

async function load() {
  await Promise.all([loadUsers(), loadTokens()]);
}

async function createUser() {
  savingUser.value = true;
  try {
    await api.post('/users', userForm);
    Object.assign(userForm, { login: '', password: '', role: 'viewer', is_active: true, group_ids: [] });
    notify('Пользователь создан');
    await loadUsers();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка создания пользователя', 'error');
  } finally {
    savingUser.value = false;
  }
}

async function patchUser(user: any, patch: Record<string, unknown>) {
  await api.patch(`/users/${user.id}`, patch);
  notify('Пользователь обновлен');
}

function openPasswordReset(user: any) {
  selectedUser.value = user;
  newPassword.value = '';
  passwordDialog.value = true;
}

async function resetPassword() {
  if (!selectedUser.value) return;
  await api.patch(`/users/${selectedUser.value.id}`, { password: newPassword.value });
  passwordDialog.value = false;
  notify('Пароль обновлен');
}

async function removeUser(user: any) {
  if (!confirm(`Удалить пользователя "${user.login}"?`)) return;
  await api.delete(`/users/${user.id}`);
  notify('Пользователь удален');
  await loadUsers();
}

async function copyText(value: string | null | undefined) {
  if (!value) return;
  await navigator.clipboard?.writeText(value);
  notify('Скопировано');
}

async function createManagedToken() {
  creatingManagedToken.value = true;
  try {
    const scopes = [
      managedTokenForm.allow_camera ? 'camera' : null,
      managedTokenForm.allow_events ? 'events' : null
    ].filter(Boolean);
    const response = await api.post('/tokens/managed-camera-tokens', {
      name: managedTokenForm.name,
      description: managedTokenForm.description || null,
      scopes,
      expires_at: managedTokenForm.expires_at ? new Date(managedTokenForm.expires_at).toISOString() : null
    });
    createdManagedToken.value = response.data.item;
    Object.assign(managedTokenForm, {
      name: '',
      description: '',
      expires_at: '',
      allow_camera: true,
      allow_events: true
    });
    notify('Управляемый токен создан');
    await loadTokens();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка создания токена', 'error');
  } finally {
    creatingManagedToken.value = false;
  }
}

async function toggleManagedToken(token: any) {
  try {
    await api.patch(`/tokens/managed-camera-tokens/${token.id}`, { is_active: !token.is_active });
    notify(token.is_active ? 'Токен отключён' : 'Токен включён');
    await loadTokens();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка изменения токена', 'error');
  }
}

async function rotateManagedToken(token: any) {
  if (!confirm(`Ротировать токен "${token.name}"? Все старые ссылки с ним перестанут работать.`)) return;
  try {
    const response = await api.post(`/tokens/managed-camera-tokens/${token.id}/rotate`, {});
    createdManagedToken.value = response.data.item;
    notify('Токен ротирован');
    await loadTokens();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка ротации токена', 'error');
  }
}

async function removeManagedToken(token: any) {
  if (!confirm(`Удалить токен "${token.name}"? Все ссылки с ним сразу перестанут работать.`)) return;
  try {
    await api.delete(`/tokens/managed-camera-tokens/${token.id}`);
    for (const cameraId of Object.keys(cameraTokenSelection)) {
      if (cameraTokenSelection[cameraId] === token.id) cameraTokenSelection[cameraId] = null;
    }
    notify('Токен удалён');
    await loadTokens();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка удаления токена', 'error');
  }
}

async function openCameraLinks(camera: any) {
  const managedTokenId = cameraTokenSelection[camera.id];
  if (!managedTokenId) {
    notify('Сначала выберите токен', 'error');
    return;
  }

  openingCameraLinks.value = camera.id;
  try {
    const response = await api.post(`/tokens/camera-links/${camera.id}`, {
      managed_token_id: managedTokenId
    });
    generatedCameraLinks.value = {
      ...generatedCameraLinks.value,
      [camera.id]: response.data
    };
    notify('Ссылки открыты с выбранным токеном');
    await loadTokens();
  } catch (err: any) {
    notify(err.response?.data?.error || err.message || 'Ошибка открытия ссылок камеры', 'error');
  } finally {
    openingCameraLinks.value = null;
  }
}

async function rotateNodeToken(node: any) {
  rotatedToken.value = (await api.post(`/dvr-servers/${node.id}/rotate-token`, {})).data;
  notify('Node token ротирован');
  await loadTokens();
}

onMounted(load);
</script>
