# Установка NewDomofon Video Master одним скриптом

Установщик предназначен для Debian 12 и выполняется от `root`. Он сам устанавливает PostgreSQL, Node.js 22, Nginx, FFmpeg, собирает приложение, применяет миграции, создаёт администратора, устанавливает systemd services, disk guard и MediaMTX RTSP gateway.

Установщик безопасно обрабатывает частично подготовленный PostgreSQL:

- если роль `newdomofon` уже существует, повторный `CREATE ROLE` не выполняется;
- пароль роли обновляется и синхронизируется с `DATABASE_URL`;
- база `newdomofon_video` создаётся только при отсутствии;
- существующая база не удаляется;
- перед миграциями существующая база сохраняется в backup.

Временная зона master автоматически устанавливается в:

```text
Europe/Moscow
MSK +0300
```

## Перед запуском

Для HTTPS домен должен указывать на этот сервер. Во внешнем firewall должны быть доступны:

```text
22/tcp    SSH
80/tcp    HTTP и Let's Encrypt
443/tcp   Web, API и media
8554/tcp  RTSP
```

Установщик не включает UFW автоматически, чтобы не заблокировать SSH. Если UFW уже активен, необходимые правила будут добавлены.

## Интерактивная установка

```bash
curl -fsSL \
  https://raw.githubusercontent.com/rirodevdom/newdomofon-video-master/main/scripts/install-master-one-shot.sh \
  -o /root/install-newdomofon-master.sh

chmod 700 /root/install-newdomofon-master.sh
bash /root/install-newdomofon-master.sh
```

Скрипт спросит домен или IP и email для Let's Encrypt.

## Неинтерактивная установка

```bash
MASTER_DOMAIN="new-video.domofon-37.ru" \
CERTBOT_EMAIL="admin@example.com" \
ADMIN_LOGIN="admin" \
  bash /root/install-newdomofon-master.sh
```

Можно передать параметры напрямую:

```bash
bash /root/install-newdomofon-master.sh \
  --domain new-video.domofon-37.ru \
  --email admin@example.com \
  --admin-login admin
```

## Установка по IP без TLS

```bash
bash /root/install-newdomofon-master.sh \
  --domain 10.106.1.30 \
  --no-tls
```

## Что делает скрипт

1. Проверяет запуск от `root` и Debian.
2. Устанавливает системные зависимости и Node.js 22.12+.
3. Настраивает `Europe/Moscow` и синхронизацию времени.
4. Клонирует актуальный `main` в `/opt/newdomofon-video-master`.
5. Создаёт или обновляет PostgreSQL role и database.
6. Генерирует production passwords и secrets.
7. Создаёт `/etc/newdomofon-video/app.env`.
8. Собирает backend и frontend.
9. Применяет migrations и seed.
10. Синхронизирует пароль web-администратора с `ADMIN_PASSWORD`.
11. Устанавливает backend, SmartYard gateways, Nginx и disk guard.
12. Устанавливает MediaMTX и автоматический RTSP gateway.
13. Пытается получить Let's Encrypt certificate.
14. Проверяет health endpoints и systemd services.
15. Печатает итоговые данные доступа.

## Итоговые данные

В конце скрипт выводит содержимое защищённого файла:

```text
/root/newdomofon-master-access.txt
```

В нём находятся:

- `ADMIN_LOGIN` и `ADMIN_PASSWORD` для web-панели;
- `DATABASE_URL` с данными PostgreSQL;
- public URL master;
- API health URL;
- RTSP URL template;
- node registration token и внутренние параметры из `app.env`;
- пути к проекту, журналу и backup.

JSON-копия:

```text
/root/newdomofon-master-access.json
```

Оба файла имеют права `0600`.

Повторно посмотреть данные:

```bash
cat /root/newdomofon-master-access.txt
jq . /root/newdomofon-master-access.json
```

## Проверка после установки

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active newdomofon-video-rtsp-gateway.service
systemctl is-active postgresql
systemctl is-active nginx

curl -fsS http://127.0.0.1:3000/api/health | jq .
curl -fsS http://127.0.0.1:3082/health | jq .

ss -lntp | grep -E ':(3000|3082|3083|3084|3085|3086|5432|8554|9997)\b'
nginx -t
```

## Если TLS не выпустился

Установка не отменяется: master остаётся доступен по HTTP. Итоговый файл покажет текущий public URL. После исправления DNS запустите установщик повторно либо выполните Certbot вручную.

## Повторный запуск

По умолчанию существующие secrets сохраняются. Пароли PostgreSQL и web-администратора синхронизируются с `app.env`.

Для намеренной ротации основных secrets:

```bash
bash /root/install-newdomofon-master.sh \
  --domain new-video.domofon-37.ru \
  --regenerate-secrets
```

На работающей системе используйте этот параметр только осознанно.

## Ошибка установки

При ошибке выводятся текущий этап, строка, exit code, путь к журналу и backup.

Журнал:

```text
/root/newdomofon-master-install-YYYYMMDD-HHMMSS.log
```

Просмотр:

```bash
tail -300 /root/newdomofon-master-install-*.log
```

Файлы доступа, `app.env` и backup содержат реальные пароли и токены. Не отправляйте их в публичные чаты и не добавляйте в Git.
