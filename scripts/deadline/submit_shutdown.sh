#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
source ../lib/config.sh
farm_require_bash4 "submit_shutdown.sh"

show_help() {
    cat << 'EOF'
Usage: ./submit_shutdown.sh [options]

Submit a suspended Deadline Command Script job that runs:
  ./shutdown.sh --deadline-postjob

Options:
  -h, --help      Show this help message
      --dry-run   Print submission details without submitting
      --with-workstation, --local
                  Include workstation shutdown in post-job command
EOF
}

DRY_RUN=0
WITH_WORKSTATION=0
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_help
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --with-workstation|--local)
            WITH_WORKSTATION=1
            ;;
        *)
            farm_die_unknown_option "$arg" show_help
            ;;
    esac
done

ALLOW_LIST="${FARM_DEADLINE_ALLOW_LIST:?Set FARM_DEADLINE_ALLOW_LIST in config/secrets.sh}"
JOB_DATE_TIME="$(TZ=Europe/Berlin date '+%d.%m.%Y %H:%M')"
if [ "$WITH_WORKSTATION" -eq 1 ]; then
    JOB_NAME="Farm PostJob Shutdown + Workstation ${JOB_DATE_TIME}"
else
    JOB_NAME="Farm PostJob Shutdown ${JOB_DATE_TIME}"
fi

"$FARM_SCRIPTS_DIR/lib/header.sh"
echo ""
farm_print_title "DEADLINE SHUTDOWN SUBMIT"
echo "Submitting farm post-job shutdown command as Suspended."
echo "Job name:   $JOB_NAME"
echo "Allow-list: $ALLOW_LIST"
if [ "$WITH_WORKSTATION" -eq 1 ]; then
    echo "Local WS:   included (--local)"
else
    echo "Local WS:   excluded"
fi
echo ""

CMD=(
    "$FARM_SCRIPTS_DIR/deadline/submit.sh"
    "--no-header"
    "--name" "$JOB_NAME"
    "--allow-list" "$ALLOW_LIST"
    "--suspended"
    "--script" "$FARM_SCRIPTS_DIR/core/shutdown.sh"
)

if [ "$DRY_RUN" -eq 1 ]; then
    CMD+=("--dry-run")
fi

CMD+=("--" "--postjob")
if [ "$WITH_WORKSTATION" -eq 1 ]; then
    CMD+=("--local")
fi

"${CMD[@]}"
