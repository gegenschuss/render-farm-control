#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
cd "$(dirname "$0")"
source ../lib/config.sh
farm_require_bash4 "submit.sh"

show_help() {
    local script_path
    script_path="$(pwd)/submit.sh"
    cat << 'EOF'
Usage: ./submit.sh [options] --script PATH [-- script_args...]

Submit a Deadline Command Script job that runs a shell command on workers.

Options:
  -h, --help                 Show this help message
      --script PATH          Script to execute on workers (required)
      --name NAME            Deadline job name (default: FARM Command Job)
      --batch-name NAME      Deadline batch name
      --pool POOL            Deadline pool
      --group GROUP          Deadline group
      --priority N           Deadline priority (0-100)
      --allow-list NAMES     Comma-separated worker allow-list (Whitelist)
      --depends-on IDS       Comma-separated Deadline job IDs dependency list
      --suspended            Submit job in Suspended state
      --no-header            Do not print the command submit title banner
      --startup-dir DIR      Startup directory for command (default: script dir)
      --dry-run              Print generated submission files, do not submit

Notes:
  - Script args must come after "--".
  - This submits using Plugin=CommandScript.
EOF
    echo ""
    echo "Examples:"
    echo "  $script_path --script ./shutdown.sh -- --deadline-postjob"
    echo "  $script_path --name \"Farm Finalizer\" --batch-name nightly \\"
    echo "    --depends-on 67f1abc,67f1abd --script ./finalize.sh \\"
    echo "    -- --grace-seconds=30"
}

SCRIPT_PATH_INPUT=""
JOB_NAME="FARM Command Job"
BATCH_NAME=""
POOL=""
GROUP=""
PRIORITY=""
ALLOW_LIST=""
DEPENDS_ON=""
STARTUP_DIR=""
DRY_RUN=0
SUSPENDED=0
NO_HEADER=0

SCRIPT_ARGS=()
PARSE_SCRIPT_ARGS=0

while [ $# -gt 0 ]; do
    if [ "$PARSE_SCRIPT_ARGS" -eq 1 ]; then
        SCRIPT_ARGS+=("$1")
        shift
        continue
    fi

    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --)
            PARSE_SCRIPT_ARGS=1
            shift
            ;;
        --script=*)
            SCRIPT_PATH_INPUT="${1#*=}"
            shift
            ;;
        --script)
            shift
            SCRIPT_PATH_INPUT="${1:-}"
            [ -n "$SCRIPT_PATH_INPUT" ] || { farm_print_error "Missing value for --script"; exit 1; }
            shift
            ;;
        --name=*)
            JOB_NAME="${1#*=}"
            shift
            ;;
        --name)
            shift
            JOB_NAME="${1:-}"
            [ -n "$JOB_NAME" ] || { farm_print_error "Missing value for --name"; exit 1; }
            shift
            ;;
        --batch-name=*)
            BATCH_NAME="${1#*=}"
            shift
            ;;
        --batch-name)
            shift
            BATCH_NAME="${1:-}"
            [ -n "$BATCH_NAME" ] || { farm_print_error "Missing value for --batch-name"; exit 1; }
            shift
            ;;
        --pool=*)
            POOL="${1#*=}"
            shift
            ;;
        --pool)
            shift
            POOL="${1:-}"
            [ -n "$POOL" ] || { farm_print_error "Missing value for --pool"; exit 1; }
            shift
            ;;
        --group=*)
            GROUP="${1#*=}"
            shift
            ;;
        --group)
            shift
            GROUP="${1:-}"
            [ -n "$GROUP" ] || { farm_print_error "Missing value for --group"; exit 1; }
            shift
            ;;
        --priority=*)
            PRIORITY="${1#*=}"
            shift
            ;;
        --priority)
            shift
            PRIORITY="${1:-}"
            [ -n "$PRIORITY" ] || { farm_print_error "Missing value for --priority"; exit 1; }
            shift
            ;;
        --allow-list=*)
            ALLOW_LIST="${1#*=}"
            shift
            ;;
        --allow-list)
            shift
            ALLOW_LIST="${1:-}"
            [ -n "$ALLOW_LIST" ] || { farm_print_error "Missing value for --allow-list"; exit 1; }
            shift
            ;;
        --depends-on=*)
            DEPENDS_ON="${1#*=}"
            shift
            ;;
        --depends-on)
            shift
            DEPENDS_ON="${1:-}"
            [ -n "$DEPENDS_ON" ] || { farm_print_error "Missing value for --depends-on"; exit 1; }
            shift
            ;;
        --startup-dir=*)
            STARTUP_DIR="${1#*=}"
            shift
            ;;
        --startup-dir)
            shift
            STARTUP_DIR="${1:-}"
            [ -n "$STARTUP_DIR" ] || { farm_print_error "Missing value for --startup-dir"; exit 1; }
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --suspended)
            SUSPENDED=1
            shift
            ;;
        --no-header)
            NO_HEADER=1
            shift
            ;;
        *)
            farm_die_unknown_option "$1" show_help
            ;;
    esac
done

if [ -z "$SCRIPT_PATH_INPUT" ]; then
    farm_print_error "--script is required"
    echo ""
    show_help
    exit 1
fi

if [ -n "${ALLOW_LIST:-}" ]; then
    IFS=',' read -ra _al_nodes <<< "$ALLOW_LIST"
    for _al_node in "${_al_nodes[@]}"; do
        local_ok=0
        _al_node="${_al_node// /}"  # trim spaces
        if printf '%s\n' "${NODES[@]}" | rg -x --fixed-strings "$_al_node" >/dev/null 2>&1; then
            local_ok=1
        fi
        # Accept Deadline worker-style names like "host-gpu1" by matching host
        # against known farm nodes or the local workstation label.
        if [ "$local_ok" -eq 0 ] && [[ "$_al_node" =~ ^(.+)-gpu[0-9]+$ ]]; then
            _al_host="${BASH_REMATCH[1]}"
            if printf '%s\n' "${NODES[@]}" | rg -x --fixed-strings "$_al_host" >/dev/null 2>&1; then
                local_ok=1
            elif [ -n "${FARM_LOCAL_NAME:-}" ] && [ "$_al_host" = "$FARM_LOCAL_NAME" ]; then
                local_ok=1
            fi
        fi
        if [ "$local_ok" -eq 0 ]; then
            farm_print_warn "allow-list node not found in config: '$_al_node'"
        fi
    done
fi

if ! command -v "$FARM_DEADLINECOMMAND" >/dev/null 2>&1 && [ "$DRY_RUN" -ne 1 ]; then
    farm_print_error "deadlinecommand not found: $FARM_DEADLINECOMMAND"
    exit 1
fi

if [ -n "$PRIORITY" ] && ! [[ "$PRIORITY" =~ ^[0-9]+$ ]]; then
    farm_print_error "--priority must be a number (0-100)"
    exit 1
fi

SCRIPT_ABS="$(cd "$(dirname "$SCRIPT_PATH_INPUT")" && pwd)/$(basename "$SCRIPT_PATH_INPUT")"
if [ ! -f "$SCRIPT_ABS" ]; then
    farm_print_error "Script not found: $SCRIPT_ABS"
    exit 1
fi

if [ -z "$STARTUP_DIR" ]; then
    STARTUP_DIR="$(cd "$(dirname "$SCRIPT_ABS")" && pwd)"
fi

quote_arg() {
    printf "%q" "$1"
}

COMMAND_LINE="bash $(quote_arg "$SCRIPT_ABS")"
for arg in "${SCRIPT_ARGS[@]}"; do
    COMMAND_LINE+=" $(quote_arg "$arg")"
done

TMP_DIR="$(mktemp -d /tmp/farm_deadline_submit_XXXXXX)"
JOB_INFO_FILE="$TMP_DIR/job_info.job"
PLUGIN_INFO_FILE="$TMP_DIR/plugin_info.job"
COMMAND_FILE="$TMP_DIR/commands.txt"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

{
    echo "Plugin=CommandScript"
    echo "Name=$JOB_NAME"
    echo "Frames=0"
    echo "ChunkSize=1"
    [ -n "$BATCH_NAME" ] && echo "BatchName=$BATCH_NAME"
    [ -n "$POOL" ] && echo "Pool=$POOL"
    [ -n "$GROUP" ] && echo "Group=$GROUP"
    [ -n "$PRIORITY" ] && echo "Priority=$PRIORITY"
    [ -n "$ALLOW_LIST" ] && echo "Whitelist=$ALLOW_LIST"
    [ -n "$DEPENDS_ON" ] && echo "JobDependencies=$DEPENDS_ON"
    [ "$SUSPENDED" -eq 1 ] && echo "InitialStatus=Suspended"
} > "$JOB_INFO_FILE"

{
    echo "StartupDirectory=$STARTUP_DIR"
} > "$PLUGIN_INFO_FILE"

{
    echo "$COMMAND_LINE"
} > "$COMMAND_FILE"

if [ "$NO_HEADER" -ne 1 ]; then
    farm_print_title "DEADLINE COMMAND SUBMIT"
fi
echo "Script:        $SCRIPT_ABS"
echo "Startup dir:   $STARTUP_DIR"
echo "Job name:      $JOB_NAME"
[ -n "$BATCH_NAME" ] && echo "Batch name:    $BATCH_NAME"
[ -n "$POOL" ] && echo "Pool:          $POOL"
[ -n "$GROUP" ] && echo "Group:         $GROUP"
[ -n "$PRIORITY" ] && echo "Priority:      $PRIORITY"
[ -n "$ALLOW_LIST" ] && echo "Allow-list:    $ALLOW_LIST"
[ -n "$DEPENDS_ON" ] && echo "Depends on:    $DEPENDS_ON"
[ "$SUSPENDED" -eq 1 ] && echo "Initial state: Suspended"
echo "Command:       $COMMAND_LINE"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    farm_print_ok "[dry-run] Submission files prepared:"
    echo "  - $JOB_INFO_FILE"
    echo "  - $PLUGIN_INFO_FILE"
    echo "  - $COMMAND_FILE"
    echo ""
    farm_print_ok "[dry-run] deadlinecommand invocation:"
    echo "  $FARM_DEADLINECOMMAND \"$JOB_INFO_FILE\" \"$PLUGIN_INFO_FILE\" \"$COMMAND_FILE\""
    exit 0
fi

SUBMIT_OUTPUT="$("$FARM_DEADLINECOMMAND" "$JOB_INFO_FILE" "$PLUGIN_INFO_FILE" "$COMMAND_FILE" 2>&1)"
SUBMIT_EXIT=$?
echo "$SUBMIT_OUTPUT"
echo ""
if [ "$SUBMIT_EXIT" -ne 0 ]; then
    farm_print_error "Deadline submission failed."
    exit "$SUBMIT_EXIT"
fi

farm_print_ok "Deadline Command Script job submitted."
