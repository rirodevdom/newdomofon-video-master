# Добавление Hikvision-node на master

Hikvision-node использует ту же ручную модель регистрации, что обычная video node: node разворачивается первой, credentials создаются на node, затем оператор создаёт совпадающую запись в интерфейсе master.

## 1. Установите Hikvision-node

На отдельном Debian 12 сервере распакуйте ZIP `newdomofon-video-hik` и выполните:

```bash
cd /root/newdomofon-video-hik-main
bash scripts/install.sh
```

После установки на node появляется root-only файл:

```text
/root/newdomofon-hik-master-registration.env
```

Он содержит:

```text
NODE_KIND=hikvision
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

## 2. Создайте node на master

Откройте:

```text
Администрирование → Ноды → Создать node
```

Выберите тип:

```text
Hikvision node
```

Введите значения из registration file посимвольно. Master не генерирует замену UUID, agent token или media secret.

До создания записи Hikvision-node продолжает работать локально, а heartbeat может возвращать `401`. После создания совпадающей записи node становится `online`.

## 3. Добавьте Hikvision-устройство

Откройте:

```text
Устройства → Добавить
```

Выберите:

```text
Тип подключения: HIKVISION
Hikvision node: созданная специализированная node
```

Укажите host, ISAPI protocol/port, RTSP port, login/password, источник архива `node|device` и retention.

Hikvision-устройство нельзя назначить обычной video node. RTSP/ONVIF-устройство нельзя назначить Hikvision-node.

## 4. Автоматическая синхронизация

После сохранения устройства master:

1. увеличивает `config_generation` node;
2. ставит команду `reload_cameras`;
3. выдаёт устройство Hikvision-node через `GET /api/node-agent/config`;
4. принимает device/channel snapshot через `POST /api/node-agent/hikvision/sync`;
5. сохраняет физические каналы и stream profiles в `hikvision_node_channels`.

Каналы Hikvision не создаются вручную. В интерфейсе устройства отображаются синхронизированные:

- physical channel;
- online/enabled;
- primary stream ID;
- main/sub/third stream settings;
- archive source;
- retention;
- время discovery.

## 5. Архитектурная граница

Master хранит пользователей, RBAC, node/device assignments и синхронизированные метаданные. Он не выполняет ISAPI-запросы, не реализует Hikvision Digest authentication и не подключается к NVR напрямую.

Hikvision-node выполняет:

- ISAPI discovery;
- получение настроек каналов;
- RTSP live;
- локальный архив при `archive_storage=node`;
- поиск и воспроизведение архива NVR при `archive_storage=device`;
- heartbeat/config/commands;
- отправку channel snapshots на master.
