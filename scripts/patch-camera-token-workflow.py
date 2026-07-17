#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1)


def remove_once(text: str, fragment: str, label: str) -> str:
    count = text.count(fragment)
    if count == 0:
        return text
    if count != 1:
        raise RuntimeError(f"{label}: expected at most one source fragment, found {count}")
    return text.replace(fragment, "", 1)


def patch_admin_view(path: Path) -> None:
    text = path.read_text(encoding="utf-8")

    text = remove_once(text, '      <v-tab value="links">Ссылки</v-tab>\n', "admin links tab")
    text = remove_once(
        text,
        '''\n      <v-window-item value="links">
        <AdminLinksPanel />
      </v-window-item>''',
        "admin links window",
    )
    text = remove_once(text, "import AdminLinksPanel from '../components/AdminLinksPanel.vue';\n", "admin links import")

    old_info = "Здесь создаются и управляются токены. Привязка токенов к камерам и готовые ссылки находятся в отдельной подвкладке «Ссылки»."
    new_info = "Здесь создаются и управляются токены. Привязка выполняется в разделе «Камеры», а готовые ссылки находятся на странице просмотра конкретной камеры."
    if new_info not in text:
        if old_info not in text:
            raise RuntimeError("admin token guidance: source text not found")
        text = text.replace(old_info, new_info, 1)

    if 'value="links"' in text or "AdminLinksPanel" in text:
        raise RuntimeError("administration links tab is still present")
    if new_info not in text:
        raise RuntimeError("new administration token guidance is missing")

    path.write_text(text, encoding="utf-8")


def patch_devices_view(path: Path) -> None:
    text = path.read_text(encoding="utf-8")

    old_selector = '''            <v-col v-if="!cameraEditingId && auth.user?.role === 'super_admin'" cols="12">
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
            </v-col>'''
    new_selector = '''            <v-col v-if="!cameraEditingId && auth.user?.role === 'super_admin'" cols="12">
              <v-select
                v-model="cameraForm.managed_token_ids"
                :items="managedTokenOptions"
                item-title="title"
                item-value="value"
                label="Токены доступа"
                hint="Можно выбрать несколько токенов. Автоматические токены назначатся камерe независимо от выбора; без пользовательских токенов останется системный fallback."
                persistent-hint
                multiple
                chips
                closable-chips
                clearable
                :loading="loadingManagedTokens"
                no-data-text="Рабочие пользовательские токены ещё не созданы"
              />
            </v-col>'''
    text = replace_once(text, old_selector, new_selector, "camera creation token selector")

    text = text.replace("managed_token_id: null", "managed_token_ids: []")

    old_save = '''    let tokenAssignmentError: string | null = null;
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
    }'''
    new_save = '''    const tokenAssignmentErrors: string[] = [];
    let assignedTokenCount = 0;
    if (cameraEditingId.value) {
      await api.patch(`/cameras/${cameraEditingId.value}/config`, payload);
    } else {
      const response = await api.post('/cameras', { ...payload, device_id: selectedDevice.value.id });
      const createdCameraId = response.data?.id || null;
      const selectedTokenIds = Array.isArray(cameraForm.managed_token_ids)
        ? Array.from(new Set(cameraForm.managed_token_ids.filter(Boolean)))
        : [];
      if (createdCameraId) {
        for (const managedTokenId of selectedTokenIds) {
          try {
            await api.post(`/tokens/camera-links/${createdCameraId}`, { managed_token_id: managedTokenId });
            assignedTokenCount += 1;
          } catch (err: any) {
            tokenAssignmentErrors.push(err.response?.data?.error || err.message || String(managedTokenId));
          }
        }
      }
    }

    cameraDialog.value = false;
    if (cameraEditingId.value) {
      notify('Настройки камеры сохранены');
    } else if (tokenAssignmentErrors.length) {
      notify(`Камера создана. Назначено токенов: ${assignedTokenCount}; ошибок: ${tokenAssignmentErrors.join('; ')}`, 'error');
    } else if (assignedTokenCount > 0) {
      notify(`Камера создана; назначено пользовательских токенов: ${assignedTokenCount}`);
    } else {
      notify('Камера создана; автоматические токены и системный fallback назначены по правилам доступа');
    }'''
    text = replace_once(text, old_save, new_save, "camera creation token assignment")

    required = (
        "cameraForm.managed_token_ids",
        'label="Токены доступа"',
        "for (const managedTokenId of selectedTokenIds)",
        "assignedTokenCount",
    )
    missing = [marker for marker in required if marker not in text]
    if missing:
        raise RuntimeError(f"camera creation token markers missing: {missing}")
    if "cameraForm.managed_token_id" in text:
        raise RuntimeError("obsolete single camera token field is still present")

    path.write_text(text, encoding="utf-8")


def patch_player_view(path: Path) -> None:
    text = path.read_text(encoding="utf-8")

    text = replace_once(
        text,
        "import { api } from '../api';",
        "import { api } from '../api';\nimport CameraTokenLinksPanel from '../components/CameraTokenLinksPanel.vue';\nimport { useAuthStore } from '../stores/auth';",
        "player token links imports",
    )
    text = replace_once(
        text,
        "const route = useRoute();",
        "const auth = useAuthStore();\nconst route = useRoute();",
        "player auth state",
    )
    text = replace_once(
        text,
        '''    </v-row>
  </v-container>''',
        '''    </v-row>

    <CameraTokenLinksPanel
      v-if="auth.user?.role === 'super_admin' && camera?.id"
      :camera-id="camera.id"
    />
  </v-container>''',
        "player token links panel",
    )

    required = (
        "CameraTokenLinksPanel",
        "auth.user?.role === 'super_admin'",
        ':camera-id="camera.id"',
    )
    missing = [marker for marker in required if marker not in text]
    if missing:
        raise RuntimeError(f"player token links markers missing: {missing}")

    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    root = Path(args.project_dir).resolve()
    targets = {
        root / "frontend/src/views/AdminView.vue": patch_admin_view,
        root / "frontend/src/views/DevicesView.vue": patch_devices_view,
        root / "frontend/src/views/PlayerView.vue": patch_player_view,
    }

    missing = [str(path) for path in targets if not path.is_file()]
    if missing:
        raise SystemExit(f"frontend source files are missing: {', '.join(missing)}")

    for path, patcher in targets.items():
        patcher(path)

    print(f"Camera token workflow UI prepared under {root}")


if __name__ == "__main__":
    main()
