#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

SYSTEM_TOKEN_ID = "00000000-0000-4000-8000-000000000001"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1)


def patch_devices_view(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if SYSTEM_TOKEN_ID in text and "managed_token_id" in text and "normalizeStreamName" in text:
        return

    text = replace_once(
        text,
        '<v-col cols="12" md="6"><v-text-field v-model="cameraForm.stream_name" label="Stream name" /></v-col>',
        '''<v-col cols="12" md="6">
              <v-text-field
                v-model="cameraForm.stream_name"
                label="Stream name"
                hint="Только латинские буквы, цифры, _ и -. Точки и пробелы будут заменены на _."
                persistent-hint
              />
            </v-col>''',
        "stream-name field",
    )

    text = replace_once(
        text,
        '<v-col cols="12" md="6"><v-switch v-model="cameraForm.is_enabled" color="primary" label="Камера включена" /></v-col>',
        '''<v-col cols="12" md="6"><v-switch v-model="cameraForm.is_enabled" color="primary" label="Камера включена" /></v-col>
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
            </v-col>''',
        "camera token selector",
    )

    text = replace_once(
        text,
        "const auth = useAuthStore();\nconst devices = ref<any[]>([]);\nconst nodes = ref<any[]>([]);",
        f"const SYSTEM_MANAGED_TOKEN_ID = '{SYSTEM_TOKEN_ID}';\nconst auth = useAuthStore();\nconst devices = ref<any[]>([]);\nconst nodes = ref<any[]>([]);\nconst managedTokens = ref<any[]>([]);",
        "managed token state",
    )

    text = replace_once(
        text,
        "const savingCamera = ref(false);\nconst resolvingOnvif = ref(false);",
        "const savingCamera = ref(false);\nconst loadingManagedTokens = ref(false);\nconst resolvingOnvif = ref(false);",
        "managed token loading state",
    )

    text = replace_once(
        text,
        "  is_enabled: true,\n  group_id: null,",
        "  is_enabled: true,\n  managed_token_id: null,\n  group_id: null,",
        "camera form token field",
    )

    text = replace_once(
        text,
        "    is_enabled: true, group_id: null, onvif_xaddr: null, onvif_port: null,",
        "    is_enabled: true, managed_token_id: null, group_id: null, onvif_xaddr: null, onvif_port: null,",
        "camera form token reset",
    )

    anchor = "const filteredDevices = computed(() => {"
    block = f'''const managedTokenOptions = computed(() => managedTokens.value
  .filter((token) => token.id !== SYSTEM_MANAGED_TOKEN_ID)
  .filter((token) => token.is_active && token.scopes?.includes('camera'))
  .filter((token) => !token.expires_at || new Date(token.expires_at).getTime() > Date.now())
  .map((token) => ({{
    title: token.expires_at ? `${{token.name}} · до ${{new Date(token.expires_at).toLocaleString()}}` : `${{token.name}} · без срока`,
    value: token.id
  }})));

function normalizeStreamName(value: unknown): string {{
  return String(value || '')
    .trim()
    .replace(/[^a-zA-Z0-9_-]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 255);
}}

{anchor}'''
    text = replace_once(text, anchor, block, "managed token options")

    old_load = '''async function load() {
  const [devicesResponse, nodesResponse] = await Promise.all([
    api.get('/devices'),
    api.get('/dvr-servers')
  ]);
  devices.value = devicesResponse.data.items || [];
  nodes.value = nodesResponse.data.items || [];
}'''
    new_load = '''async function loadManagedTokens() {
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
}'''
    text = replace_once(text, old_load, new_load, "managed token load")

    text = replace_once(
        text,
        '''function openCameraCreate() {
  if (!selectedDevice.value) return;
  cameraEditingId.value = null;
  resetCameraForm();
  cameraDialog.value = true;
}''',
        '''async function openCameraCreate() {
  if (!selectedDevice.value) return;
  cameraEditingId.value = null;
  resetCameraForm();
  await loadManagedTokens();
  cameraDialog.value = true;
}''',
        "camera create opener",
    )

    text = replace_once(
        text,
        '''    if (!cameraForm.name.trim() || !cameraForm.stream_name.trim()) {
      notify('Укажите название и stream name камеры', 'error');
      return;
    }''',
        '''    const normalizedStreamName = normalizeStreamName(cameraForm.stream_name);
    cameraForm.stream_name = normalizedStreamName;
    if (!cameraForm.name.trim() || !normalizedStreamName) {
      notify('Укажите название и корректный stream name камеры', 'error');
      return;
    }''',
        "stream-name validation",
    )

    text = replace_once(
        text,
        "      stream_name: cameraForm.stream_name,",
        "      stream_name: normalizedStreamName,",
        "normalized stream payload",
    )

    old_save = '''    if (cameraEditingId.value) {
      await api.patch(`/cameras/${cameraEditingId.value}/config`, payload);
    } else {
      await api.post('/cameras', { ...payload, device_id: selectedDevice.value.id });
    }

    cameraDialog.value = false;
    notify(cameraEditingId.value ? 'Настройки камеры сохранены' : 'Камера создана');'''
    new_save = '''    let tokenAssignmentError: string | null = null;
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
      notify('Камера создана; выбранный пользовательский токен заменил системный');
    } else {
      notify('Камера создана; назначен внутренний системный токен');
    }'''
    text = replace_once(text, old_save, new_save, "camera token assignment")

    path.write_text(text, encoding="utf-8")


def patch_admin_links(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "У камеры всегда один текущий токен" in text and "Заменить текущий токен" in text:
        return
    replacements = [
        (
            "Нажмите на камеру, затем выберите один из уже привязанных токенов или добавьте новый. Ссылки формируются для конкретной пары «камера + токен». HLS, MPEG-TS, DASH и JPEG работают через HTTPS gateway. RTSP показывается только когда на сервере настроен публичный RTSP gateway.",
            "У камеры всегда один текущий токен. Внутренний системный токен назначается автоматически, а выбранный пользовательский токен заменяет его. Live и архив используют этот текущий токен.",
            "links info",
        ),
        ("Привязанные токены", "Текущий токен", "current token title"),
        ("Добавить токен", "Заменить текущий токен", "replace token title"),
        ("Привязать и показать", "Заменить и показать", "replace token button"),
        (
            "notify(response.data.assignment_added ? 'Токен привязан, ссылки сформированы' : 'Ссылки сформированы');",
            "notify('Текущий токен установлен, ссылки сформированы');",
            "token replacement notification",
        ),
    ]
    for old, new, label in replacements:
        text = replace_once(text, old, new, label)
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()
    root = Path(args.project_dir)
    devices = root / "frontend/src/views/DevicesView.vue"
    links = root / "frontend/src/components/AdminLinksPanel.vue"
    if not devices.is_file() or not links.is_file():
        raise SystemExit(f"frontend source files are missing under {root}")
    patch_devices_view(devices)
    patch_admin_links(links)
    print(f"Managed-token UI patch applied under {root}")


if __name__ == "__main__":
    main()
