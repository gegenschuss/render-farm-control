#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#

farm_install_check_state() {
    local mode="$1"
    local label="$2"
    local cmd="$3"
    local result
    result=$(bash -c "$cmd" 2>/dev/null)
    if [ -z "$result" ] || [[ "$result" == "not installed" ]]; then
        printf "  %-12s  \e[31mnot installed\e[0m\n" "$label:"
    else
        if [ "$mode" = "houdini" ]; then
            printf "  %-12s  \e[32m%s\e[0m\n" "$label:" "$(basename "$result")"
        else
            printf "  %-12s  \e[32m%s\e[0m\n" "$label:" "$result"
        fi
    fi
}

farm_install_build_deadline_remote_script() {
    local filename="$1"
    local search_dir="$2"
    local install_dir="$3"
    cat << EOF
echo ""
echo -e "${FARM_C_RULE}============================================================${FARM_C_RESET}"
echo "  INSTALLING:"
echo "  $filename"
echo -e "${FARM_C_RULE}============================================================${FARM_C_RESET}"
echo ""
echo "  Step 1: Preparing directory..."
rm -rf "$install_dir" && mkdir -p "$install_dir"
cd "$install_dir"
echo "  Step 2: Copying file..."
cp "$search_dir/$filename" .
echo "  Step 3: Extracting..."
tar -xf "$filename"
echo "  Step 4: Installing..."
echo ""
RUN_FILE=\$(find . -name "DeadlineClient-*-linux-x64-installer.run" | head -n 1)
if [ -n "\$RUN_FILE" ]; then
    chmod +x "\$RUN_FILE"
    sudo "\$RUN_FILE" \
        --mode unattended \
        --prefix "$FARM_DEADLINE_PREFIX" \
        --connectiontype Direct \
        --repositorydir "$FARM_DEADLINE_REPO_DIR" \
        --licensemode LicenseFree \
        --launcherdaemon true \
        --daemonuser \$(whoami) \
        --slavestartup false
fi
echo ""
echo "  Step 5: Cleanup..."
cd ~ && rm -rf "$install_dir"
echo ""
echo "--- VERIFICATION ---"
[ -d "$FARM_DEADLINE_PREFIX" ] \
    && echo -e "\e[32m[OK]\e[0m Installed" \
    || echo -e "\e[31m[FAIL]\e[0m Missing"
echo ""
echo -e "${FARM_C_RULE}============================================================${FARM_C_RESET}"
echo "  DONE! Press [RETURN] to close."
echo -e "${FARM_C_RULE}============================================================${FARM_C_RESET}"
read
EOF
}

farm_install_build_deadline_local_script() {
    local local_name="$1"
    local filename="$2"
    local search_dir="$3"
    local install_dir="$4"
    cat << EOF
echo ""
echo -e "${FARM_C_RULE}============================================================${FARM_C_RESET}"
echo "  INSTALLING $local_name:"
echo "  $filename"
echo -e "${FARM_C_RULE}============================================================${FARM_C_RESET}"
echo ""
echo "  Step 1: Preparing directory..."
rm -rf "$install_dir" && mkdir -p "$install_dir"
cd "$install_dir"
echo "  Step 2: Copying file..."
cp "$search_dir/$filename" .
echo "  Step 3: Extracting..."
tar -xf "$filename"
echo "  Step 4: Installing..."
echo ""
RUN_FILE=\$(find . -name "DeadlineClient-*-linux-x64-installer.run" | head -n 1)
if [ -n "\$RUN_FILE" ]; then
    chmod +x "\$RUN_FILE"
    echo "  Please enter your password for sudo:"
    sudo "\$RUN_FILE" \
        --mode unattended \
        --prefix "$FARM_DEADLINE_PREFIX" \
        --connectiontype Direct \
        --repositorydir "$FARM_DEADLINE_REPO_DIR" \
        --licensemode LicenseFree \
        --launcherdaemon false \
        --daemonuser \$(whoami) \
        --slavestartup false
fi
echo ""
echo "  Step 5: Cleanup..."
cd ~ && rm -rf "$install_dir"
echo ""
echo "--- VERIFICATION ---"
[ -d "$FARM_DEADLINE_PREFIX" ] \
    && echo -e "\e[32m[OK]\e[0m Installed" \
    || echo -e "\e[34m[INFO]\e[0m GUI Mode: Launcher disabled."
echo ""
echo -e "${FARM_C_RULE}============================================================${FARM_C_RESET}"
echo "  DONE! Press [RETURN] to close."
echo -e "${FARM_C_RULE}============================================================${FARM_C_RESET}"
read
EOF
}

farm_install_build_houdini_cmd() {
    local filename="$1"
    local search_dir="$2"
    local install_dir="$3"
    cat << EOF
echo '';
echo -e "${FARM_C_RULE}============================================================${FARM_C_RESET}";
echo '  INSTALLING:';
echo '  $filename';
echo -e "${FARM_C_RULE}============================================================${FARM_C_RESET}";
echo '';
rm -rf "$install_dir";
mkdir -p "$install_dir";
cd "$install_dir";
echo '  Step 1: Copying file...';
cp "$search_dir/$filename" .;
echo '  Step 2: Extracting...';
tar -xf "$filename";
echo '  Step 3: Entering directory...';
cd houdini-*/;
echo '  Step 4: Installing...';
echo '';
sudo ./houdini.install --auto-install \
  --accept-EULA 2021-10-13 \
  --install-houdini \
  --install-license \
  --install-sidefxlabs \
  --install-menus;
echo '';
echo '  Step 5: Cleanup...';
cd ~;
rm -rf "$install_dir";
echo '';
echo -e "${FARM_C_RULE}============================================================${FARM_C_RESET}";
echo '  DONE! Press Enter to close.';
echo -e "${FARM_C_RULE}============================================================${FARM_C_RESET}";
read line
EOF
}
