#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
source ../lib/config.sh

show_help() {
    local script_path
    script_path="$(pwd)/finalize.sh"
    cat << 'EOF'
Usage: ./finalize.sh [options]

Deadline batch finalizer script.
Use as a single dependent "finalizer" job that runs only after all batch jobs finish.

Options:
  -h, --help               Show this help message
      --grace-seconds=SEC  Wait SEC before shutdown (default: 30)
      --no-shutdown        Log completion but do not trigger shutdown
      --dry-run            Print what would happen and exit

Behavior:
  - non-interactive
  - writes log file to /tmp/finalize.log
  - triggers: ./shutdown.sh --deadline-postjob

Deadline setup (Monitor):
  1) Submit all render jobs first.
  2) Submit ONE finalizer command job:
       /path/to/scripts/finalize.sh --grace-seconds=30
  3) Set the finalizer job dependency to "all jobs in batch".
  4) Enable "Resume On Failed Dependencies" only if you want shutdown even when
     some render jobs fail.
EOF
    echo ""
    echo "Examples:"
    echo "  $script_path"
    echo "  $script_path --grace-seconds=120"
    echo "  $script_path --no-shutdown"
    echo "  $script_path --dry-run"
}

GRACE_SECONDS=30
NO_SHUTDOWN=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_help
            exit 0
            ;;
        --grace-seconds=*)
            GRACE_SECONDS="${arg#*=}"
            ;;
        --no-shutdown)
            NO_SHUTDOWN=1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        *)
            farm_print_error "Unknown option: $arg"
            echo ""
            show_help
            exit 1
            ;;
    esac
done

if ! [[ "$GRACE_SECONDS" =~ ^[0-9]+$ ]]; then
    farm_print_error "Invalid --grace-seconds value: $GRACE_SECONDS"
    exit 1
fi

LOG_FILE="/tmp/finalize.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deadline batch finalizer started."
echo "Script path: $(pwd)/finalize.sh"
echo "Grace seconds: $GRACE_SECONDS"
echo "No-shutdown mode: $NO_SHUTDOWN"
echo "Dry-run mode: $DRY_RUN"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] Would sleep ${GRACE_SECONDS}s."
    if [ "$NO_SHUTDOWN" -eq 1 ]; then
        echo "[dry-run] Would skip shutdown by flag."
    else
        echo "[dry-run] Would run: $(pwd)/shutdown.sh --deadline-postjob"
    fi
    echo ""
    farm_print_ok "Finalizer dry-run complete."
    exit 0
fi

if [ "$GRACE_SECONDS" -gt 0 ]; then
    echo "Waiting ${GRACE_SECONDS}s grace period before post-job action..."
    sleep "$GRACE_SECONDS"
fi

if [ "$NO_SHUTDOWN" -eq 1 ]; then
    farm_print_ok "Batch finalized. Shutdown skipped by flag."
    exit 0
fi

echo "Triggering post-job shutdown..."
"$(pwd)/shutdown.sh" --deadline-postjob
EXIT_CODE=$?
echo ""
echo "Post-job shutdown exit code: $EXIT_CODE"
exit "$EXIT_CODE"
