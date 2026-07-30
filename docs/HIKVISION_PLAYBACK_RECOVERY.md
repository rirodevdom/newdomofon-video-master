# Hikvision playback recovery contract

The Hikvision player starts live playback before optional archive metadata.
Transient 404/5xx responses from a restarting Hikvision node are retried by the frontend adapters instead of requiring a page reload.

Archive range failures must not disable `archiveGaps` or clear previously known ranges. A successfully prepared archive session is inserted as a provisional timeline range until the full-retention range query succeeds.

Requests opened at the live edge are shifted behind it by 90 seconds so the NVR has time to finalize the recording interval.
