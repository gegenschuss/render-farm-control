#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
source ../lib/config.sh
farm_require_bash4 "autowake.sh"

SERVICE_NAME="farm-autowake.service"
TIMER_NAME="farm-autowake.timer"
LEGACY_SERVICE_NAME="farm-deadline-prejob-wake.service"
LEGACY_TIMER_NAME="farm-deadline-prejob-wake.timer"
UNIT_DIR="$HOME/.config/systemd/user"
SERVICE_PATH="$UNIT_DIR/$SERVICE_NAME"
TIMER_PATH="$UNIT_DIR/$TIMER_NAME"
LEGACY_SERVICE_PATH="$UNIT_DIR/$LEGACY_SERVICE_NAME"
LEGACY_TIMER_PATH="$UNIT_DIR/$LEGACY_TIMER_NAME"
WAKE_CMD="/usr/bin/bash $FARM_BASE_DIR/scripts/core/wake.sh --silent --prejob-wait=45"

show_help() {
    cat << EOF
Usage: ./autowake.sh <command>

Manage systemd timer/service for Deadline prejob auto-wake.

Commands:
  install      Install or update unit files under ~/.config/systemd/user
  enable       Enable + start timer immediately
  run-now      Trigger auto-wake service immediately (non-blocking)
  disable      Disable + stop timer
  uninstall    Disable timer and remove unit files
  status       Show enabled/active state
  ensure-installed
               Validate unit files exist; prints install hint if missing
  has-units    Quiet check; exit 0 if unit files exist, 1 otherwise
  is-enabled   Quiet check; exit 0 if timer is enabled, 1 otherwise
  -h, --help   Show this help message
EOF
}

require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        farm_print_error "systemctl not found on this workstation."
        exit 1
    fi
}

has_units() {
    [ -f "$SERVICE_PATH" ] && [ -f "$TIMER_PATH" ]
}

print_install_hint() {
    farm_print_warn "AutoWake systemd unit files not found."
    echo "Expected:"
    echo "  - $SERVICE_PATH"
    echo "  - $TIMER_PATH"
    echo ""
    echo "Install with:"
    echo "  bash \"$FARM_BASE_DIR/autowake.sh\" install"
}

ensure_installed() {
    if ! has_units; then
        print_install_hint
        return 1
    fi
    return 0
}

install_units() {
    require_systemd
    farm_print_title "INSTALL DEADLINE PREJOB AUTOWAKE TIMER"
    mkdir -p "$UNIT_DIR"

    # Migrate from legacy unit names if present.
    systemctl --user disable --now "$LEGACY_TIMER_NAME" >/dev/null 2>&1 || true
    rm -f "$LEGACY_SERVICE_PATH" "$LEGACY_TIMER_PATH"

    tee "$SERVICE_PATH" >/dev/null << EOF
[Unit]
Description=Farm Deadline prejob auto-wake
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$WAKE_CMD
EOF

    tee "$TIMER_PATH" >/dev/null << EOF
[Unit]
Description=Run Farm Deadline prejob auto-wake every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
AccuracySec=1min
Persistent=true
Unit=$SERVICE_NAME

[Install]
WantedBy=timers.target
EOF

    printf "  %s..." "Reloading systemd daemon"
    if systemctl --user daemon-reload; then
        printf " ${FARM_C_OK}ok${FARM_C_RESET}\n"
    else
        printf " ${FARM_C_ERR}FAILED${FARM_C_RESET}\n"
    fi
    farm_print_ok "Installed unit files:"
    echo "  - $SERVICE_PATH"
    echo "  - $TIMER_PATH"
    echo ""
    echo "Next step: run this script with 'enable' to activate timer."
    echo "Optional for headless runs: sudo loginctl enable-linger $USER"
}

enable_timer() {
    require_systemd
    if ! ensure_installed; then
        exit 1
    fi

    printf "  %s..." "Reloading systemd daemon"
    if systemctl --user daemon-reload; then
        printf " ${FARM_C_OK}ok${FARM_C_RESET}\n"
    else
        printf " ${FARM_C_ERR}FAILED${FARM_C_RESET}\n"
    fi
    printf "  %s..." "Enabling and starting $TIMER_NAME"
    if systemctl --user enable --now "$TIMER_NAME"; then
        printf " ${FARM_C_OK}ok${FARM_C_RESET}\n"
    else
        printf " ${FARM_C_ERR}FAILED${FARM_C_RESET}\n"
    fi
    farm_print_ok "Enabled timer: $TIMER_NAME"
}

run_now() {
    require_systemd
    if ! ensure_installed; then
        exit 1
    fi
    printf "  %s..." "Reloading systemd daemon"
    if systemctl --user daemon-reload; then
        printf " ${FARM_C_OK}ok${FARM_C_RESET}\n"
    else
        printf " ${FARM_C_ERR}FAILED${FARM_C_RESET}\n"
    fi
    printf "  %s..." "Starting $SERVICE_NAME"
    if systemctl --user start --no-block "$SERVICE_NAME"; then
        printf " ${FARM_C_OK}ok${FARM_C_RESET}\n"
    else
        printf " ${FARM_C_ERR}FAILED${FARM_C_RESET}\n"
    fi
    farm_print_ok "Triggered service: $SERVICE_NAME"
}

disable_timer() {
    require_systemd
    if ! ensure_installed; then
        exit 1
    fi
    systemctl --user disable --now "$TIMER_NAME" >/dev/null 2>&1 || true
    farm_print_ok "Disabled timer: $TIMER_NAME"
}

uninstall_units() {
    require_systemd
    systemctl --user disable --now "$TIMER_NAME" >/dev/null 2>&1 || true
    systemctl --user disable --now "$LEGACY_TIMER_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_PATH" "$TIMER_PATH" "$LEGACY_SERVICE_PATH" "$LEGACY_TIMER_PATH"
    systemctl --user daemon-reload
    farm_print_ok "Removed unit files:"
    echo "  - $SERVICE_PATH"
    echo "  - $TIMER_PATH"
}

status_timer() {
    require_systemd
    local enabled=0
    local active=0

    systemctl --user is-enabled --quiet "$TIMER_NAME" && enabled=1
    systemctl --user is-active --quiet "$TIMER_NAME" && active=1

    echo "enabled=$enabled"
    echo "active=$active"
    echo "timer=$TIMER_NAME"
    echo "service=$SERVICE_NAME"
}

is_enabled_timer() {
    require_systemd
    if ! has_units; then
        return 1
    fi
    systemctl --user is-enabled --quiet "$TIMER_NAME"
}

COMMAND="${1:-}"
case "$COMMAND" in
    install) install_units ;;
    enable) enable_timer ;;
    run-now) run_now ;;
    disable) disable_timer ;;
    uninstall) uninstall_units ;;
    status) status_timer ;;
    ensure-installed) ensure_installed ;;
    has-units) has_units ;;
    is-enabled) is_enabled_timer ;;
    -h|--help|"")
        show_help
        ;;
    *)
        farm_die_unknown_option "$COMMAND" show_help
        ;;
esac
