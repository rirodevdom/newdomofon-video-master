# Master/node live-first rollout

Безопасный порядок восстановления распределённой установки.

## Цель

Master запускает backend, frontend, PostgreSQL и compatibility gateways. В strict master/node production он не записывает камеры.

Обычная video node получает назначенные камеры через `/api/node-agent/config`, читает RTSP, записывает live и локальный архив, обслуживает signed media URL и ONVIF events.

## 1. Стабилизировать live

На master:

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-smartyard-compat.service
curl -fsS http://127.0.0.1:3000/api/health | jq
```

На node:

```bash
systemctl is-active newdomofon-video-dvr.service
curl -fsS http://127.0.0.1:3010/health | jq
curl -fsS http://127.0.0.1:3010/recorders | jq
journalctl -u newdomofon-video-dvr -n 200 --no-pager
```

На время диагностики можно отключить программное распознавание движения и ONVIF events, не затрагивая запись:

```bash
ENV_FILE=/etc/newdomofon-video/app.env
sed -i -E '/^(VIDEO_MOTION_ENABLED|ONVIF_EVENTS_ENABLED)=/d' "$ENV_FILE"
printf '%s\n' \
  'VIDEO_MOTION_ENABLED=false' \
  'ONVIF_EVENTS_ENABLED=false' >>"$ENV_FILE"
systemctl restart newdomofon-video-dvr.service
```

Live считается стабильным, когда рекордеры не завершаются, `live.m3u8` обновляется, а в журнале нет сетевых timeout к подсети камер.

## 2. Проверить локальный архив

```bash
curl -fsS http://127.0.0.1:3010/recorders | jq
find /var/lib/newdomofon-video/dvr -type f \
  \( -name '*.ts' -o -name 'live.m3u8' \) \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\n' | tail -30
```

После появления завершённых сегментов проверьте ranges и воспроизведение через веб-плеер master.

## 3. Включить ONVIF events

Только после стабильного live:

```bash
ENV_FILE=/etc/newdomofon-video/app.env
sed -i -E '/^ONVIF_EVENTS_ENABLED=/d' "$ENV_FILE"
echo 'ONVIF_EVENTS_ENABLED=true' >>"$ENV_FILE"
systemctl restart newdomofon-video-dvr.service
```

Проверяйте локальную SQLite node и timeline через master. Программное обнаружение движения включайте только для камер без пригодных ONVIF events.

## Vendor-specific функции

Обычная video node не содержит vendor-specific event collectors, поиска каналов или архива устройства. Такие функции должны работать только в отдельном специализированном сервисе и не включаются в этот runbook.
