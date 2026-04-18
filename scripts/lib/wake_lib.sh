#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#

run_or_print() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "${FARM_C_WARN}[dry-run]${FARM_C_RESET} $*"
        return 0
    fi
    "$@"
}

# Returns:
# 0 = offline, send WOL and boot to linux
# 1 = on windows idle, reboot to linux
# 2 = artist working or update active, skip
# 3 = already on linux
# 5 = silent policy skip (currently on Windows)
check_dualboot_status() {
    local NAME=$1
    local WIN_USER=$2

    detect_node_os "$NAME"
    local OS_STATUS=$?

    case $OS_STATUS in
        0)
            echo "$(farm_node_tag "$NAME") offline - sending WOL..."
            return 0
            ;;
        2)
            echo "$(farm_node_tag "$NAME") already on Linux - ready!"
            return 3
            ;;
        1)
            local result_code=2
            if [ "$DEADLINE_PREJOB" -eq 1 ]; then
                echo "$(farm_node_tag "$NAME") on Windows - skipped by silent policy."
                result_code=5
            else
                echo "$(farm_node_tag "$NAME") is on Windows - checking for active users..."
                print_windows_tasks "$NAME"

                local LOGGED_IN
                LOGGED_IN=$(farm_ssh_batch "${NAME}-win" \
                    'powershell -Command "(Get-WMIObject Win32_ComputerSystem).UserName"' \
                    2>/dev/null)
                if echo "$LOGGED_IN" | grep -qi "$WIN_USER"; then
                    farm_print_warn "$NAME: ARTIST ($WIN_USER) WORKING - skipped by default."
                    result_code=2
                else
                    echo "$(farm_node_tag "$NAME") checking for active Windows updates..."
                    local UPDATE_ACTIVE
                    UPDATE_ACTIVE=$(farm_ssh_batch "${NAME}-win" \
                        'powershell -Command "Get-Process -Name TiWorker,wuauclt,WUDFHost -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name"' \
                        2>/dev/null)
                    if echo "$UPDATE_ACTIVE" | grep -qi "TiWorker\|wuauclt\|WUDFHost"; then
                        farm_print_warn "$NAME: WINDOWS UPDATE ACTIVE - skipped by default."
                        result_code=2
                    else
                        echo "$(farm_node_tag "$NAME") Windows idle - will reboot to Linux"
                        result_code=1
                    fi
                fi
            fi
            return "$result_code"
            ;;
    esac
}

make_dualboot_script() {
    local NAME=$1
    local BIOS_GUID=$2
    local LINUX_WAIT=$3
    local STATUS=$4

    cat << EOF
show_timer() {
    local seconds=0
    local label=\$1
    local target=\$2
    while kill -0 \$target 2>/dev/null; do
        printf "\r\${label}: %02d:%02d" \$((seconds/60)) \$((seconds%60))
        sleep 1
        ((seconds++))
    done
    printf "\r\${label}: fertig!          \n"
}

$(if [ "$STATUS" -eq 2 ]; then
cat << SKIP
echo -e "${FARM_C_WARN}ARTIST WORKING or UPDATE ACTIVE - node skipped${FARM_C_RESET}"
SKIP
elif [ "$STATUS" -eq 3 ]; then
cat << READY
echo -e "${FARM_C_OK}Already on Linux - ready!${FARM_C_RESET}"
READY
else
cat << BOOT
echo "[$NAME] Warte auf Windows SSH..."
seconds=0
while ! ssh -F ~/.ssh/config -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=ERROR ${NAME}-win "echo ok" &>/dev/null; do
    printf "\r[$NAME] SSH versuch: %02d:%02d" \$((seconds/60)) \$((seconds%60))
    sleep 5
    ((seconds+=5))
    if [ \$seconds -ge 300 ]; then
        echo ""
        echo "[$NAME] TIMEOUT: Windows SSH nicht erreichbar!"
        exit 1
    fi
done
echo ""
echo "[$NAME] Windows erreichbar - sende Reboot nach Linux..."

ssh -F ~/.ssh/config -o BatchMode=yes -o LogLevel=ERROR ${NAME}-win "powershell -Command \"bcdedit /set '{fwbootmgr}' bootsequence '$BIOS_GUID'\""
sleep 2
ssh -F ~/.ssh/config -o BatchMode=yes -o LogLevel=ERROR ${NAME}-win "shutdown /r /t 5"

echo "[$NAME] Warte auf Linux-Boot..."
sleep $LINUX_WAIT &
SLEEP_PID=\$!
show_timer "[$NAME] Linux Boot " \$SLEEP_PID
wait \$SLEEP_PID

echo "[$NAME] Warte auf Ping..."
seconds=0
while ! ping -c 1 -W 1 "$NAME" &>/dev/null; do
    printf "\r[$NAME] Ping: warte... %02d:%02d" \$((seconds/60)) \$((seconds%60))
    sleep 2
    ((seconds+=2))
done

echo ""
echo -e "${FARM_C_OK}NODE: $NAME ist ONLINE (Linux) bereit!${FARM_C_RESET}"
sleep 5
BOOT
fi)
EOF
}
