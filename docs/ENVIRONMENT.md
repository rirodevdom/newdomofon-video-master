# Переменные окружения video master

Основной production-файл:

```text
/etc/newdomofon-video/app.env
```

Шаблон:

```text
deploy/env/master.env.example
```

После изменения backend-параметров:

```bash
systemctl restart newdomofon-video-backend.service
```

После изменения media/SmartYard/RTSP-параметров перезапустите соответствующие gateway services или повторно запустите `scripts/deploy-master.sh`.

Файл содержит пароли и secrets. Рекомендуемые права:

```bash
chown root:newdomofon /etc/newdomofon-video/app.env
chmod 0640 /etc/newdomofon-video/app.env
```

## 1. Backend и PostgreSQL

| Переменная | Назначение |
|---|---|
| `NODE_ENV` | Режим Node.js. В production должно быть `production`. |
| `BACKEND_PORT` | Локальный HTTP-порт backend API. Стандартно `3000`. |
| `DATABASE_URL` | PostgreSQL connection string. Содержит пароль БД и не должен публиковаться. |
| `JWT_SECRET` | Secret для пользовательских JWT. Минимум 32 случайных символа; изменение завершает действующие sessions. |
| `ADMIN_LOGIN` | Login bootstrap/admin пользователя. |
| `ADMIN_PASSWORD` | Пароль bootstrap/admin. В production минимум 12 символов; после изменения требуется перезапуск backend/seed workflow в зависимости от версии. |
| `TRUST_PROXY` | Доверять ли reverse-proxy headers. За Nginx на production обычно `true`. |
| `CORS_ORIGIN` | Разрешённый origin frontend. Обычно публичный HTTPS URL master. |
| `NODE_COMMAND_POLL_LIMIT` | Максимум команд, выдаваемых node за один poll. По умолчанию `20`. |

## 2. Публичные URL и playback

| Переменная | Назначение |
|---|---|
| `APP_PUBLIC_URL` | Канонический публичный URL приложения/master. Используется при формировании ссылок и redirects. |
| `SMARTYARD_PUBLIC_BASE_URL` | Публичная база SmartYard-compatible media URLs. Обычно равна `APP_PUBLIC_URL`. |
| `MEDIA_PUBLIC_BASE_URL` | Публичный path/base legacy media API. Обычно `/api/media`. |
| `DVR_ENGINE_URL` | Локальный fallback DVR URL. На strict master recorder отключён; значение остаётся loopback для совместимости. |
| `PLAYBACK_TOKEN_TTL_SECONDS` | Срок жизни короткоживущих внутренних playback tokens. Стандартно `900` секунд. |
| `INTERNAL_DVR_SECRET` | Внутренний secret для trusted ingest/legacy compatibility. Не является `DVR_NODE_MEDIA_SECRET` конкретной node. |

## 3. Регистрация video node

Актуальная схема — **operator-defined credentials**:

1. node разворачивается первой;
2. оператор задаёт `DVR_MASTER_URL`, UUID, agent token, media secret и URLs;
3. те же значения вводятся в `Администрирование → Ноды → Создать node`;
4. master ничего не генерирует.

Credentials конкретной node **не хранятся в master `app.env`**. Они хранятся в PostgreSQL:

- `DVR_NODE_ID` → `dvr_servers.id`;
- SHA-256(`DVR_NODE_TOKEN`) → `agent_token_hash`;
- `DVR_NODE_MEDIA_SECRET` → `media_secret`;
- `DVR_MASTER_URL` → `capabilities.manual_registration.master_url`.

| Переменная master env | Назначение |
|---|---|
| `NODE_REGISTRATION_TOKEN` | Legacy token для endpoint self-registration. В текущей ручной схеме оставлять пустым. Не использовать для новых node. |

Подробно: [MANUAL_NODE_REGISTRATION.md](MANUAL_NODE_REGISTRATION.md).

## 4. Master disk guard

| Переменная | Назначение |
|---|---|
| `MASTER_DISK_GUARD_PATHS` | Список проверяемых путей через `:`. Обычно `/`, PostgreSQL data и log directory. |
| `MASTER_DISK_MIN_FREE_BYTES` | Минимум свободных байт до critical. |
| `MASTER_DISK_MIN_FREE_PERCENT` | Минимум свободного места в процентах до critical. |
| `MASTER_DISK_RESUME_FREE_BYTES` | Byte-порог выхода из critical. |
| `MASTER_DISK_RESUME_FREE_PERCENT` | Процентный порог выхода из critical. |
| `MASTER_DISK_MIN_FREE_INODES_PERCENT` | Минимум свободных inode до critical. |
| `MASTER_DISK_RESUME_FREE_INODES_PERCENT` | Порог inode для восстановления. |
| `MASTER_JOURNAL_MAX_SIZE` | Верхняя граница disk usage journald для проекта/сервера. |
| `MASTER_JOURNAL_MAX_AGE` | Максимальный возраст journal records. |
| `MASTER_DISK_STALE_TMP_MINUTES` | Возраст временных файлов, после которого guard может их удалить. |
| `MASTER_DISK_APT_CLEAN_ON_CRITICAL` | Разрешить `apt-get clean` при critical system disk. |

При critical backend может запрещать изменяющие операции и возвращать HTTP `507`.

## 5. RTSP gateway / MediaMTX

| Переменная | Назначение |
|---|---|
| `RTSP_GATEWAY_ENABLED` | Включён ли automatic RTSP gateway. После установки MediaMTX обычно `true`. |
| `RTSP_PUBLIC_HOST` | DNS/IP master для внешнего RTSP URL. |
| `RTSP_PUBLIC_PORT` | Публичный TCP-порт RTSP. Стандартно `8554`. |
| `RTSP_PUBLIC_URL_TEMPLATE` | Шаблон RTSP URL, обычно `rtsp://token:{token}@host:8554/{stream}`. |
| `RTSP_GATEWAY_SHARED_SECRET` | Secret backend ↔ MediaMTX auth/control. Генерируется installer и не публикуется. |
| `RTSP_RELAY_PUBLISH_SECRET` | Secret локального relay publisher. Генерируется installer. |
| `RTSP_AUTO_OPEN_FIREWALL` | Автоматически добавить port в ufw/firewalld, если firewall поддерживается. |
| `RTSP_MEDIAMTX_VERSION` | Зафиксированная версия MediaMTX. Пусто — installer определяет актуальную поддерживаемую версию. |

Обычный RTSP не шифрует credentials и media. Ограничивайте `8554/tcp` VPN или доверенными адресами.

## 6. Public events

| Переменная | Назначение |
|---|---|
| `PUBLIC_EVENTS_INCLUDE_PASSIVE` | Включать пассивные false/inactive state snapshots в публичный timeline по умолчанию. Обычно `false`. |
| `ONVIF_EVENT_SUPPRESS_REPEATED_STATE` | Не сохранять повтор одного и того же ONVIF state без изменения. Обычно `true`. |

## 7. Переменные deploy/install scripts

Эти параметры управляют shell scripts, а не backend runtime:

| Переменная | Назначение |
|---|---|
| `PROJECT_DIR` | Путь к checkout master. |
| `ENV_FILE` | Путь к production env. |
| `WEB_ROOT` | Каталог опубликованного frontend, обычно `/var/www/newdomofon-video`. |
| `INSTALL_DISK_GUARD` | Устанавливать/обновлять master disk guard. |
| `INSTALL_JOURNAL_LIMITS` | Устанавливать journald limits. |
| `INSTALL_RTSP_GATEWAY` | Устанавливать/обновлять MediaMTX RTSP gateway. |
| `BACKUP_ROOT` | Каталог backup для rollout/install scripts. |

## 8. Генерация secrets

```bash
DB_PASSWORD="$(openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-')"
JWT_SECRET="$(openssl rand -hex 48)"
ADMIN_PASSWORD="$(openssl rand -base64 36 | tr -d '\n')"
INTERNAL_DVR_SECRET="$(openssl rand -hex 32)"
```

Node-specific secrets создаются на самой node, а не этой командой на master.

## 9. Безопасная проверка без вывода secrets

```bash
ENV_FILE=/etc/newdomofon-video/app.env

for key in \
  DATABASE_URL \
  JWT_SECRET \
  ADMIN_PASSWORD \
  APP_PUBLIC_URL \
  SMARTYARD_PUBLIC_BASE_URL \
  INTERNAL_DVR_SECRET; do
  if grep -qE "^${key}=.+" "$ENV_FILE"; then
    echo "$key=SET"
  else
    echo "$key=MISSING"
  fi
done
```

Для URL можно выводить значения отдельно, но не выводите `DATABASE_URL`, passwords и secrets в общий журнал.

## 10. Какие изменения требуют дополнительных действий

| Изменение | Действие |
|---|---|
| Backend/JWT/CORS/DB | Перезапустить `newdomofon-video-backend.service`. |
| Public URL/Nginx/TLS | Проверить `nginx -t`, reload Nginx и media links. |
| RTSP settings/secrets | Повторно запустить `scripts/install-rtsp-gateway.sh`, затем проверить MediaMTX. |
| Disk guard thresholds | Запустить `newdomofon-video-master-disk-guard.service` вручную для проверки. |
| Node token/media secret | Изменить одинаково на node и через «Задать новые credentials» на master; перезапустить DVR node. |
