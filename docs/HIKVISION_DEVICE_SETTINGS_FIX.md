# Hikvision device settings persistence

The Devices edit form is hydrated through Vue reactivity. Loading an existing
Hikvision device must not be treated as an operator-requested connection type
change, because the type-change watcher clears the selected node and resets
Hikvision-specific defaults.

`scripts/patch-hikvision-device-settings.py` is idempotent and is executed by
both backend and frontend build preparation. It:

- preserves saved Hikvision device fields while opening the edit dialog;
- keeps the existing reset behavior when an operator actually changes the type;
- makes dashboard configured-state handling recognize Hikvision devices using
  name, assigned node, host and ISAPI port.
