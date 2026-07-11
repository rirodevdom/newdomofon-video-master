<template>
  <v-container fluid class="pa-6">
    <h1 class="text-h4 mb-4">Администрирование</h1>
    <v-tabs v-model="tab"><v-tab value="users">Пользователи</v-tab><v-tab value="tokens">Токены</v-tab></v-tabs>
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
                <td><v-select v-model="user.role" :items="roles" density="compact" hide-details @update:model-value="patchUser(user, { role: user.role })" /></td>
                <td><v-switch v-model="user.is_active" color="primary" density="compact" hide-details @update:model-value="patchUser(user, { is_active: user.is_active })" /></td>
                <td>{{ formatDate(user.created_at) }}</td>
                <td class="text-right"><v-btn size="small" variant="tonal" @click="openPasswordReset(user)">Сброс пароля</v-btn><v-btn size="small" color="error" variant="tonal" class="ml-2" @click="removeUser(user)">Удалить</v-btn></td>
              </tr>
              <tr v-if="!users.length"><td colspan="5" class="text-center py-6">Пользователи не найдены</td></tr>
            </tbody>
          </v-table>
        </v-card>
      </v-window-item>

      <v-window-item value="tokens">
        <v-row>
          <v-col cols="12" md="6">
            <v-card>
              <v-card-title>Системные токены</v-card-title>
              <v-table><tbody>
                <tr><td>Node registration token</td><td><v-chip size="small" :color="tokens.node_registration_token?.configured ? 'success' : 'error'">{{ tokens.node_registration_token?.configured ? 'configured' : 'missing' }}</v-chip></td></tr>
                <tr><td>Internal DVR secret</td><td><v-chip size="small" :color="tokens.internal_dvr_secret?.configured ? 'success' : 'error'">{{ tokens.internal_dvr_secret?.configured ? 'configured' : 'missing' }}</v-chip></td></tr>
              </tbody></v-table>
            </v-card>
          </v-col>
          <v-col cols="12" md="6"><v-alert type="info" variant="tonal">Одна камера может иметь несколько управляемых токенов. Добавление нового токена не удаляет существующие привязки.</v-alert></v-col>
        </v-row>

        <v-card class="mt-4">
          <v-card-title>Node agent/media tokens</v-card-title>
          <v-table>
            <thead><tr><th>Node</th><th>Agent</th><th>Media</th><th>Создан</th><th></th></tr></thead>
            <tbody><tr v-for="node in tokens.node_tokens || []" :key="node.id">
              <td>{{ node.name }}</td>
              <td><v-chip size="small" :color="node.has_agent_token ? 'success' : 'error'">{{ node.has_agent_token ? 'configured' : 'missing' }}</v-chip></td>
              <td><v-chip size="small" :color="node.has_media_secret ? 'success' : 'error'">{{ node.has_media_secret ? 'configured' : 'missing' }}</v-chip></td>
              <td>{{ formatDate(node.created_at) }}</td>
              <td class="text-right"><v-btn size="small" variant="tonal" @click="rotateNodeToken(node)">Ротировать</v-btn></td>
            </tr></tbody>
          </v-table>
        </v-card>

        <v-card class="mt-4 pa-4">
          <v-card-title class="px-0">Создать управляемый токен камер</v-card-title>
          <v-row>
            <v-col cols="12" md="3"><v-text-field v-model="managedTokenForm.name" label="Название токена" /></v-col>
            <v-col cols="12" md="4"><v-text-field v-model="managedTokenForm.description" label="Описание" /></v-col>
            <v-col cols="12" md="3"><v-text-field v-model="managedTokenForm.expires_at" type="datetime-local" label="Истекает" /></v-col>
            <v-col cols="6" md="1"><v-switch v-model="managedTokenForm.allow_camera" label="Видео" hide-details /></v-col>
            <v-col cols="6" md="1"><v-switch v-model="managedTokenForm.allow_events" label="События" hide-details /></v-col>
          </v-row>
          <v-btn color="primary" :loading="creatingManagedToken" :disabled="!managedTokenForm.name.trim()" @click="createManagedToken">Создать токен</v-btn>
        </v-card>

        <v-alert v-if="createdManagedToken" type="warning" variant="tonal" class="mt-4">
          <v-textarea :model-value="createdManagedToken.token" label="Значение токена" rows="2" readonly />
          <v-btn size="small" variant="tonal" @click="copyText(createdManagedToken.token)">Копировать</v-btn>
        </v-alert>

        <v-card class="mt-4">
          <v-card-title>Управляемые токены</v-card-title>
          <v-table>
            <thead><tr><th>Название</th><th>Права</th><th>Статус</th><th>Камеры</th><th>Истекает</th><th></th></tr></thead>
            <tbody>
              <tr v-for="token in managedTokens" :key="token.id">
                <td><div class="font-weight-medium">{{ token.name }}</div><div class="text-caption">{{ token.description }}</div></td>
                <td><v-chip v-for="scope in token.scopes" :key="scope" size="x-small" class="mr-1">{{ scope === 'camera' ? 'Видео' : 'События' }}</v-chip></td>
                <td><v-chip size="small" :color="managedTokenStatus(token).color">{{ managedTokenStatus(token).text }}</v-chip></td>
                <td><span>{{ token.assigned_cameras?.length || 0 }}</span><div class="text-caption">{{ (token.assigned_cameras || []).map((camera: any) => camera.name).join(', ') }}</div></td>
                <td>{{ formatDate(token.expires_at) }}</td>
                <td class="text-right" style="white-space: nowrap">
                  <v-btn size="small" variant="text" icon="mdi-content-copy" @click="copyText(token.token)" />
                  <v-btn size="small" variant="text" icon="mdi-refresh" @click="rotateManagedToken(token)" />
                  <v-btn size="small" variant="text" :icon="token.is_active ? 'mdi-pause-circle-outline' : 'mdi-play-circle-outline'" @click="toggleManagedToken(token)" />
                  <v-btn size="small" color="error" variant="text" icon="mdi-delete-outline" @click="removeManagedToken(token)" />
                </td>
              </tr>
            </tbody>
          </v-table>
        </v-card>

        <v-card class="mt-4">
          <v-card-title>Ссылки камер</v-card-title>
          <v-card-subtitle class="pb-3">Все привязанные токены отображаются у камеры. Выберите токен, чтобы добавить его или повторно получить ссылку.</v-card-subtitle>
          <v-table>
            <thead><tr><th>Камера</th><th>Stream</th><th>Node</th><th style="min-width: 360px">Привязанные токены</th><th style="min-width: 260px">Добавить / открыть</th><th></th></tr></thead>
            <tbody>
              <template v-for="camera in tokens.camera_links || []" :key="camera.id">
                <tr>
                  <td>{{ camera.name }}</td><td><code>{{ camera.stream_name }}</code></td><td>{{ camera.node_name || '—' }}</td>
                  <td>
                    <div v-if="cameraAssignments(camera.id).length" class="d-flex flex-wrap ga-1">
                      <v-chip v-for="token in cameraAssignments(camera.id)" :key="token.id" size="small" :color="managedTokenStatus(token).color" closable @click:close="detachToken(token, camera)">
                        {{ token.name }}
                      </v-chip>
                    </div>
                    <span v-else class="text-medium-emphasis">Нет привязок</span>
                  </td>
                  <td>
                    <v-select v-model="cameraTokenSelection[camera.id]" :items="cameraManagedTokenOptions" item-title="option_title" item-value="id" density="compact" hide-details placeholder="Выберите токен" />
                  </td>
                  <td class="text-right"><v-btn size="small" color="primary" variant="tonal" :disabled="!selectedTokenUsable(camera.id)" :loading="openingCameraLinks === camera.id" @click="openCameraLinks(camera)">{{ isAssigned(camera.id, cameraTokenSelection[camera.id]) ? 'Показать ссылку' : 'Добавить и открыть' }}</v-btn></td>
                </tr>
                <tr v-if="generatedCameraLinks[camera.id]"><td colspan="6" class="pb-4">
                  <v-alert type="info" variant="tonal" density="compact" class="mb-2">Токен «{{ generatedCameraLinks[camera.id].managed_token?.name }}». Остальные привязки камеры сохранены.</v-alert>
                  <v-textarea :model-value="generatedCameraLinks[camera.id].smartyard_url" label="SmartYard URL" rows="2" readonly />
                  <div class="d-flex ga-2 flex-wrap"><v-btn size="small" variant="tonal" @click="copyText(generatedCameraLinks[camera.id].smartyard_url)">Копировать SmartYard</v-btn><v-btn size="small" variant="tonal" @click="copyText(generatedCameraLinks[camera.id].live_url)">Live</v-btn><v-btn size="small" variant="tonal" @click="copyText(generatedCameraLinks[camera.id].events_url_template)">Events</v-btn></div>
                </td></tr>
              </template>
            </tbody>
          </v-table>
        </v-card>

        <v-alert v-if="rotatedToken" type="warning" variant="tonal" class="mt-4"><pre>{{ rotatedTokenText }}</pre></v-alert>
      </v-window-item>
    </v-window>

    <v-dialog v-model="passwordDialog" max-width="520"><v-card><v-card-title>Сброс пароля: {{ selectedUser?.login }}</v-card-title><v-card-text><v-text-field v-model="newPassword" label="Новый пароль" type="password" /></v-card-text><v-card-actions><v-spacer /><v-btn @click="passwordDialog = false">Отмена</v-btn><v-btn color="primary" @click="resetPassword">Сохранить</v-btn></v-card-actions></v-card></v-dialog>
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
const managedTokenForm = reactive({ name: '', description: '', expires_at: '', allow_camera: true, allow_events: true });
const userForm = reactive({ login: '', password: '', role: 'viewer', is_active: true, group_ids: [] });

function notify(text: string, type: 'success' | 'error' = 'success') { message.value = text; messageType.value = type; }
function formatDate(value: string | null | undefined) { return value ? new Date(value).toLocaleString() : 'не истекает'; }
function managedTokenStatus(token: any) { if (!token.is_active) return { text: 'отключён', color: 'error' }; if (token.expires_at && new Date(token.expires_at).getTime() <= Date.now()) return { text: 'истёк', color: 'warning' }; return { text: 'активен', color: 'success' }; }
function isManagedTokenUsable(token: any) { return Boolean(token?.is_active && token.scopes?.includes('camera') && (!token.expires_at || new Date(token.expires_at).getTime() > Date.now())); }
const cameraManagedTokenOptions = computed(() => managedTokens.value.filter((token) => token.scopes?.includes('camera')).map((token) => ({ ...token, option_title: isManagedTokenUsable(token) ? token.name : `${token.name} (${managedTokenStatus(token).text})` })));
const rotatedTokenText = computed(() => rotatedToken.value ? [`DVR_NODE_ID=${rotatedToken.value.node_id || rotatedToken.value.id}`, `DVR_NODE_TOKEN=${rotatedToken.value.agent_token || ''}`, rotatedToken.value.media_secret ? `DVR_NODE_MEDIA_SECRET=${rotatedToken.value.media_secret}` : ''].filter(Boolean).join('\n') : '');

function cameraAssignments(cameraId: string) { return managedTokens.value.filter((token) => (token.assigned_cameras || []).some((camera: any) => camera.id === cameraId)); }
function isAssigned(cameraId: string, tokenId: string | null | undefined) { return Boolean(tokenId && cameraAssignments(cameraId).some((token) => token.id === tokenId)); }
function selectedTokenUsable(cameraId: string) { return isManagedTokenUsable(managedTokens.value.find((token) => token.id === cameraTokenSelection[cameraId])); }

async function loadUsers() { users.value = (await api.get('/users')).data.items || []; }
async function loadTokens() {
  const [systemResponse, managedResponse] = await Promise.all([api.get('/tokens'), api.get('/tokens/managed-camera-tokens')]);
  tokens.value = systemResponse.data || {};
  managedTokens.value = managedResponse.data.items || [];
  for (const camera of tokens.value.camera_links || []) {
    const assigned = cameraAssignments(camera.id);
    if (!cameraTokenSelection[camera.id] || !managedTokens.value.some((token) => token.id === cameraTokenSelection[camera.id])) cameraTokenSelection[camera.id] = assigned[0]?.id || null;
  }
}
async function load() { await Promise.all([loadUsers(), loadTokens()]); }
async function createUser() { savingUser.value = true; try { await api.post('/users', userForm); Object.assign(userForm, { login: '', password: '', role: 'viewer', is_active: true, group_ids: [] }); notify('Пользователь создан'); await loadUsers(); } catch (err: any) { notify(err.response?.data?.error || err.message, 'error'); } finally { savingUser.value = false; } }
async function patchUser(user: any, patch: any) { await api.patch(`/users/${user.id}`, patch); notify('Пользователь обновлён'); }
function openPasswordReset(user: any) { selectedUser.value = user; newPassword.value = ''; passwordDialog.value = true; }
async function resetPassword() { if (!selectedUser.value) return; await api.patch(`/users/${selectedUser.value.id}`, { password: newPassword.value }); passwordDialog.value = false; notify('Пароль обновлён'); }
async function removeUser(user: any) { if (!confirm(`Удалить пользователя «${user.login}»?`)) return; await api.delete(`/users/${user.id}`); await loadUsers(); }
async function copyText(value: string) { if (value) await navigator.clipboard?.writeText(value); notify('Скопировано'); }

async function createManagedToken() { creatingManagedToken.value = true; try { const scopes = [managedTokenForm.allow_camera ? 'camera' : null, managedTokenForm.allow_events ? 'events' : null].filter(Boolean); const response = await api.post('/tokens/managed-camera-tokens', { name: managedTokenForm.name, description: managedTokenForm.description || null, scopes, expires_at: managedTokenForm.expires_at ? new Date(managedTokenForm.expires_at).toISOString() : null }); createdManagedToken.value = response.data.item; Object.assign(managedTokenForm, { name: '', description: '', expires_at: '', allow_camera: true, allow_events: true }); notify('Токен создан'); await loadTokens(); } catch (err: any) { notify(err.response?.data?.error || err.message, 'error'); } finally { creatingManagedToken.value = false; } }
async function toggleManagedToken(token: any) { await api.patch(`/tokens/managed-camera-tokens/${token.id}`, { is_active: !token.is_active }); await loadTokens(); }
async function rotateManagedToken(token: any) { if (!confirm(`Ротировать токен «${token.name}»?`)) return; const response = await api.post(`/tokens/managed-camera-tokens/${token.id}/rotate`, {}); createdManagedToken.value = response.data.item; await loadTokens(); }
async function removeManagedToken(token: any) { if (!confirm(`Удалить токен «${token.name}»?`)) return; await api.delete(`/tokens/managed-camera-tokens/${token.id}`); await loadTokens(); }
async function detachToken(token: any, camera: any) { if (!confirm(`Убрать токен «${token.name}» у камеры «${camera.name}»?`)) return; await api.delete(`/tokens/managed-camera-tokens/${token.id}/cameras/${camera.id}`); notify('Привязка удалена'); await loadTokens(); }
async function openCameraLinks(camera: any) { const tokenId = cameraTokenSelection[camera.id]; if (!tokenId) return; openingCameraLinks.value = camera.id; try { const response = await api.post(`/tokens/camera-links/${camera.id}`, { managed_token_id: tokenId }); generatedCameraLinks.value = { ...generatedCameraLinks.value, [camera.id]: response.data }; notify(isAssigned(camera.id, tokenId) ? 'Ссылка открыта' : 'Токен добавлен к камере'); await loadTokens(); } catch (err: any) { notify(err.response?.data?.error || err.message, 'error'); } finally { openingCameraLinks.value = null; } }
async function rotateNodeToken(node: any) { if (!confirm(`Ротировать credentials node «${node.name}»?`)) return; rotatedToken.value = (await api.post(`/dvr-servers/${node.id}/rotate-token`, {})).data; notify('Credentials node ротированы'); await loadTokens(); }

onMounted(load);
</script>
