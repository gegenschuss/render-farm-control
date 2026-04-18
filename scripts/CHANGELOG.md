# Farm Scripts Changelog

## v2.1
- Unified menu status line into one compact row with Pulse included.
- Added dynamic local workstation name support via `FARM_LOCAL_NAME`.
- Merged operational flows into shared engines:
  - `farm_node_session.sh` (control/nvtop)
  - `farm_install_app.sh` (houdini/deadline)
  - `farm_power_action.sh` (shutdown/reboot)
- Added reusable libs for wake/install internals:
  - `farm_wake_lib.sh`
  - `farm_install_lib.sh`
- Added `farm_selftest.sh` with optional `--deep` mode.
- Added version constant `FARM_VERSION` in `farm_config.sh`.
- Added `p` quick selftest action to launcher menu.
