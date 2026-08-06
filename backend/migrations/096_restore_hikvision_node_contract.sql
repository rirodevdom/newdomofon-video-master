BEGIN;

-- Repair databases that were already affected by the legacy 093 migration being
-- re-run after the modern Hikvision node contract had been introduced.
-- hikvision_node_channels is authoritative evidence that a device belongs to a
-- Hikvision node. It survives the accidental HIKVISION -> RTSP conversion, so it
-- lets us restore the device type and assignment without guessing hosts, names or
-- credentials.
WITH recovered AS (
  SELECT
    h.device_id,
    MIN(h.dvr_server_id::text)::uuid AS dvr_server_id,
    CASE
      WHEN COUNT(DISTINCT h.archive_storage) = 1 THEN MIN(h.archive_storage)
      ELSE NULL
    END AS archive_storage
  FROM public.hikvision_node_channels h
  JOIN public.dvr_servers s
    ON s.id = h.dvr_server_id
   AND s.capabilities->>'node_kind' = 'hikvision'
  GROUP BY h.device_id
  HAVING COUNT(DISTINCT h.dvr_server_id) = 1
)
UPDATE public.devices d
   SET connection_type = 'HIKVISION',
       dvr_server_id = recovered.dvr_server_id,
       archive_storage = COALESCE(recovered.archive_storage, d.archive_storage)
  FROM recovered
 WHERE d.id = recovered.device_id
   AND (
     d.connection_type IS DISTINCT FROM 'HIKVISION'
     OR d.dvr_server_id IS DISTINCT FROM recovered.dvr_server_id
     OR (
       recovered.archive_storage IS NOT NULL
       AND d.archive_storage IS DISTINCT FROM recovered.archive_storage
     )
   );

COMMIT;
