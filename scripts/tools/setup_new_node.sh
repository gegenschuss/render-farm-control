#!/bin/bash
#       _____                          __
#      / ___/__ ___ ____ ___  ___ ____/ /  __ _____ ___
#     / (_ / -_) _ `/ -_) _ \(_-</ __/ _ \/ // (_-<(_-<
#     \___/\__/\_, /\__/_//_/___/\__/_//_/\_,_/___/___/
#             /___/
#
set -Eeuo pipefail

on_error() {
    echo "FEHLER in Zeile $1: Setup wurde abgebrochen."
}
trap 'on_error $LINENO' ERR

# ============================================
#   RENDER NODE SETUP
#
#   Provisions a fresh Ubuntu or Rocky Linux machine as a
#   Deadline 10 render node with Houdini, NVIDIA drivers,
#   Wake-on-LAN, autofs CIFS mounts, and a TTY1 dashboard.
#
#   Supported: Ubuntu 22.04/24.04, Rocky Linux 9/10
#
#   Prerequisites on the new node:
#     - Clean OS install with a user account
#     - Network connectivity (wired, DHCP)
#     - SSH server running (sudo apt install openssh-server)
#
#   Quick-start (from your Mac/workstation):
#
#     1. Edit config/secrets.sh — fill in the SETUP_* variables:
#        SETUP_NODE_NAME        hostname for this node
#        SETUP_NODE_IP          local LAN IP (for Deadline worker override)
#        SETUP_STUDIO_USER      SMB user for studio share
#        SETUP_STUDIO_PASS      SMB password for studio share
#        SETUP_DEADLINE_PASS    SMB password for Deadline repository
#        SETUP_WORKSTATION_USER SMB user for workstation shares
#        SETUP_WORKSTATION_PASS SMB password for workstation shares
#        SETUP_NAS_IP           NAS / file server IP
#        SETUP_DEADLINE_IP      Deadline repository server IP
#        SETUP_WORKSTATION_HOST workstation hostname (SSH / SMB)
#        SETUP_AUTOFS_MAP_NAME  autofs map filename (e.g. auto.myfarm)
#        SETUP_SEARCH_DIR_HOUDINI  path to Houdini installer tarballs
#        SETUP_SEARCH_DIR_DEADLINE path to Deadline installer tarballs
#
#     2. Copy this project to the new node:
#        scp -r /path/to/farm <user>@<node-ip>:~/farm
#
#     3. SSH in and run the setup:
#        ssh <user>@<node-ip>
#        cd ~/farm && sudo bash setup_new_node.sh
#
#     4. After setup: connect Tailscale and license Houdini
#        sudo tailscale up
#        sudo /usr/lib/sesi/sesictrl login
#        sudo /usr/lib/sesi/sesictrl redeem
#
#   The script is idempotent — safe to re-run after errors or
#   reboots. Progress is tracked in /var/tmp/render-node-setup.state.
#   Delete the state file to force a full re-run.
# ============================================

# Load secrets (node name, IPs, passwords).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../../config/secrets.sh" ]; then
    source "$SCRIPT_DIR/../../config/secrets.sh"
else
    echo "ERROR: secrets.sh not found in $SCRIPT_DIR" >&2
    echo "Copy secrets.example.sh to secrets.sh and fill in the SETUP_* variables." >&2
    exit 1
fi

# SETUP VARIABLEN ---
NODE_NAME="${SETUP_NODE_NAME:?Set SETUP_NODE_NAME in config/secrets.sh}"
NODE_IP="${SETUP_NODE_IP:?Set SETUP_NODE_IP in config/secrets.sh}"
STUDIO_USER="${SETUP_STUDIO_USER:?Set SETUP_STUDIO_USER in config/secrets.sh}"
STUDIO_PASS="${SETUP_STUDIO_PASS:?Set SETUP_STUDIO_PASS in config/secrets.sh}"
DEADLINE_PASS="${SETUP_DEADLINE_PASS:?Set SETUP_DEADLINE_PASS in config/secrets.sh}"
WORKSTATION_PASS="${SETUP_WORKSTATION_PASS:?Set SETUP_WORKSTATION_PASS in config/secrets.sh}"
WORKSTATION_HOST="${SETUP_WORKSTATION_HOST:?Set SETUP_WORKSTATION_HOST in config/secrets.sh}"
WORKSTATION_SMB_USER="${SETUP_WORKSTATION_USER:-rendering}"
AUTOFS_MAP_NAME="${SETUP_AUTOFS_MAP_NAME:-auto.farm}"
SEARCH_DIR_HOUDINI="${SETUP_SEARCH_DIR_HOUDINI:?Set SETUP_SEARCH_DIR_HOUDINI in config/secrets.sh}"
SEARCH_DIR_DEADLINE="${SETUP_SEARCH_DIR_DEADLINE:?Set SETUP_SEARCH_DIR_DEADLINE in config/secrets.sh}"
HOUDINI_EULA_DATE="2021-10-13"   # update when SideFX issues a new EULA
STATE_FILE="/var/tmp/render-node-setup.state"
APT_UPDATED=0

# OS DETECTION ---
. /etc/os-release
OS_ID="${ID}"            # ubuntu, rocky
OS_VERSION="${VERSION_ID}"  # 22.04, 24.04, 9.x
echo "Erkanntes OS: $OS_ID $OS_VERSION"

case "$OS_ID" in
    ubuntu)
        PM_UPDATE="sudo apt-get update"
        PM_INSTALL="sudo apt-get install -y"
        PM_UPGRADE="sudo apt-get upgrade -y"
        PM_PURGE="sudo apt-get purge -y"
        ;;
    rocky)
        PM_UPDATE="sudo dnf makecache"
        PM_INSTALL="sudo dnf install -y"
        PM_UPGRADE="sudo dnf upgrade -y"
        PM_PURGE="sudo dnf remove -y"
        ;;
    *)
        echo "FEHLER: Nicht unterstütztes OS '$OS_ID $OS_VERSION'. Unterstützt: ubuntu 22/24, rocky 9/10."
        exit 1
        ;;
esac

# Distro-specific package names
if [ "$OS_ID" = "ubuntu" ]; then
    if [ "$OS_VERSION" = "24.04" ]; then
        PKG_ALSA="libasound2t64"
        PKG_XSS="libxss1t64"
    else
        PKG_ALSA="libasound2"
        PKG_XSS="libxss1"
    fi
    # software-properties-common provides add-apt-repository (not always pre-installed on server)
    PKGS_BASE="cifs-utils nfs-common python3 build-essential htop nvtop autofs nano snapd ethtool curl sed mawk libglu1-mesa software-properties-common"
    PKGS_HOUDINI="libopengl0 libgl1 libglx0 libegl1 libxcursor1 libxcomposite1 libxdamage1 libxi6 libxtst6 libnss3 libxrandr2 ${PKG_ALSA}"
    PKGS_DEADLINE="file libgdiplus libgl1 libsm6 libice6 libxext6 libxrender1 fontconfig libx11-6 ${PKG_XSS}"
elif [ "$OS_ID" = "rocky" ]; then
    RHEL_MAJOR="${OS_VERSION%%.*}"   # 9 or 10
    # Bootstrap packages: must be installed before EPEL/CRB-dependent packages
    PKGS_BASE_PRE="dnf-plugins-core epel-release"
    # Remaining base packages: htop/nvtop/mesa-libGLU require EPEL+CRB to be active first
    PKGS_BASE="cifs-utils nfs-utils python3 gcc make htop nvtop autofs nano ethtool curl sed gawk mesa-libGLU"
    PKGS_HOUDINI="libglvnd-opengl mesa-libGL libglvnd-glx libglvnd-egl libXcursor libXcomposite libXdamage libXi libXtst nss libXrandr alsa-lib"
    PKGS_DEADLINE="file libgdiplus mesa-libGL libSM libICE libXext libXrender fontconfig libX11 libXScrnSaver"
fi

step_done() {
    local step="$1"
    [ -f "$STATE_FILE" ] && grep -q "^${step}=done$" "$STATE_FILE"
}

mark_step_done() {
    local step="$1"
    if ! step_done "$step"; then
        printf "%s=done\n" "$step" >> "$STATE_FILE"
    fi
}

apt_update_once() {
    if [ "$APT_UPDATED" -eq 0 ]; then
        $PM_UPDATE
        APT_UPDATED=1
    fi
}

write_root_file_if_changed() {
    local target="$1"
    local mode="${2:-0644}"
    local tmp
    tmp=$(mktemp)
    cat > "$tmp"

    if sudo test -f "$target" && sudo cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi

    sudo install -m "$mode" "$tmp" "$target"
    rm -f "$tmp"
    return 0
}

write_user_file_if_changed() {
    local target="$1"
    local mode="${2:-0644}"
    local tmp
    tmp=$(mktemp)
    cat > "$tmp"

    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi

    install -m "$mode" "$tmp" "$target"
    rm -f "$tmp"
    return 0
}

# Helper: check whether a systemd unit exists.
service_exists() {
    systemctl list-unit-files --quiet "$1" 2>/dev/null
}

echo "Starte Full Render Node Setup für $NODE_NAME"

# TTY1 MODE AUSWAHL ---
TTY1_MODE="render_dashboard"  # default: dedicated render node
if ! step_done "bashrc_dashboard"; then
    echo ""
    echo "Ist das ein Windows Dual-Boot System?"
    read -r -n 1 -p "  [J/N, Enter = N]: " _tty1_choice </dev/tty
    echo ""
    if [[ "${_tty1_choice}" == "j" || "${_tty1_choice}" == "J" || "${_tty1_choice}" == "y" || "${_tty1_choice}" == "Y" ]]; then
        TTY1_MODE="nvtop"
    fi
fi

# BASIS-SYSTEM & TOOLS ---
if step_done "base_system_tools"; then
    echo "Basis-System & Tools bereits erledigt - überspringe."
else
    apt_update_once
    $PM_UPGRADE
    if [ "$OS_ID" = "rocky" ]; then
        # Phase 1: bootstrap EPEL and CRB — must be active before EPEL-dependent packages
        $PM_INSTALL $PKGS_BASE_PRE
        sudo crb enable          # enables CodeReady Builder (PowerTools) repo
        APT_UPDATED=0            # force cache refresh so dnf sees EPEL + CRB
        apt_update_once
    fi
    $PM_INSTALL $PKGS_BASE
    mark_step_done "base_system_tools"
fi

# TAILSCALE ---
if command -v tailscale >/dev/null 2>&1; then
    echo "Tailscale bereits installiert - überspringe."
else
    echo "Installiere Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "Tailscale installiert. Verbinde mit: sudo tailscale up"
fi

# CONSOLE FONT & DISPLAY FIX (Ubuntu only — uses debconf/console-setup) ---
if [ "$OS_ID" = "ubuntu" ]; then
    echo "Konfiguriere Konsolen-Schriftart (Terminus)..."

    if step_done "console_setup"; then
        echo "Console-Setup bereits erledigt - überspringe."
    else
        sudo apt-get install -y debconf-utils

        sudo debconf-set-selections <<EOF
console-setup console-setup/charmap select UTF-8
console-setup console-setup/codeset select Combined - Latin; Slavic Cyrillic; Greek
console-setup console-setup/fontface select Terminus
console-setup console-setup/fontsize select 8x16
EOF

        sudo DEBIAN_FRONTEND=noninteractive dpkg-reconfigure console-setup
        sudo update-initramfs -u -k all
        sudo setupcon
        mark_step_done "console_setup"
    fi
else
    echo "Console-Setup übersprungen (nicht Ubuntu)."
fi

# GRUB AUFLÖSUNG ---
# Ubuntu uses 'splash' (Plymouth); Rocky does not — splash causes a harmless
# but noisy warning on RHEL-based systems without Plymouth configured.
echo "Konfiguriere GRUB Auflösung (1280x720)..."
if [ "$OS_ID" = "ubuntu" ]; then
    GRUB_CMDLINE="quiet splash video=1280x720"
else
    GRUB_CMDLINE="quiet video=1280x720"
fi
if [ -f /etc/default/grub ]; then
    if ! grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE}\"" /etc/default/grub; then
        sudo sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE}\"/" /etc/default/grub
        if [ "$OS_ID" = "ubuntu" ]; then
            sudo update-grub
        elif [ "$OS_ID" = "rocky" ]; then
            if [ -d /sys/firmware/efi ]; then
                sudo grub2-mkconfig -o /boot/efi/EFI/rocky/grub.cfg
            else
                sudo grub2-mkconfig -o /boot/grub2/grub.cfg
            fi
        fi
        echo "GRUB Auflösung gesetzt."
    else
        echo "GRUB Auflösung bereits korrekt gesetzt - überspringe."
    fi
else
    echo "Hinweis: /etc/default/grub nicht gefunden - überspringe."
fi

# SUDO NOPASSWD CONFIG ---
echo "Konfiguriere passwortlose sudo-Rechte für remote Update..."

# Wir erstellen eine eigene Datei in /etc/sudoers.d/
# Das ist sauberer als die Hauptdatei zu editieren.
if write_root_file_if_changed "/etc/sudoers.d/${NODE_NAME}_cmds" 0440 <<EOF
$NODE_NAME ALL=(ALL) NOPASSWD: ALL
EOF
then
    echo "Sudoers-Datei aktualisiert."
else
    echo "Sudoers-Datei bereits aktuell."
fi

echo "Sudo-Rechte wurden aktualisiert."

# Preserve DEBIAN_FRONTEND through sudo (Ubuntu only)
if [ "$OS_ID" = "ubuntu" ]; then
    echo 'Defaults env_keep += "DEBIAN_FRONTEND"' | sudo tee /etc/sudoers.d/apt-env
    sudo chmod 440 /etc/sudoers.d/apt-env
fi

# HARDWARE-OPTIMIERUNG: WAKE-ON-LAN & GPU POWER ---
# Erkennt die primäre Netzwerkkarte automatisch
NIC=$(ip -o link show up | awk -F': ' '$2 != "lo" {print $2; exit}')
if [ -z "$NIC" ]; then
    NIC=$(ip route | awk '/default/ {print $5; exit}')
fi

echo "Konfiguriere WoL für $NIC..."

if [ -n "$NIC" ]; then
# Wake-on-LAN Service
if write_root_file_if_changed "/etc/systemd/system/wol.service" <<EOF
[Unit]
Description=Enable Wake-on-LAN
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s $NIC wol g
[Install]
WantedBy=multi-user.target
EOF
then
    echo "wol.service aktualisiert."
    sudo systemctl daemon-reload
else
    echo "wol.service bereits aktuell."
fi

sudo systemctl enable --now wol.service
else
    echo "Warnung: Kein aktives Netzwerk-Interface erkannt, WoL-Service wird übersprungen."
fi
if service_exists "gpu-power.service"; then
    sudo systemctl enable gpu-power.service
else
    echo "Hinweis: gpu-power.service nicht gefunden - überspringe."
fi

# SELINUX & FIREWALLD (Rocky only) ---
# Disabled on render nodes: SELinux enforcing mode blocks CIFS mounts, Deadline,
# and NVIDIA/CUDA. firewalld blocks Deadline Launcher port 17000.
# These nodes live on a trusted LAN — the security tradeoff is acceptable.
if [ "$OS_ID" = "rocky" ]; then
    echo "Deaktiviere SELinux..."
    if [ -f /etc/selinux/config ]; then
        sudo sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
        # Also set permissive for the current session without reboot
        if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
            sudo setenforce 0
        fi
        echo "SELinux deaktiviert (dauerhaft nach Reboot, aktuell: permissive)."
    else
        echo "Hinweis: /etc/selinux/config nicht gefunden - überspringe."
    fi

    echo "Deaktiviere firewalld..."
    if service_exists "firewalld.service"; then
        sudo systemctl disable --now firewalld
        echo "firewalld deaktiviert."
    else
        echo "Hinweis: firewalld nicht gefunden - überspringe."
    fi
fi

# NVIDIA TREIBER ---
if command -v nvidia-smi >/dev/null 2>&1; then
    echo "NVIDIA Treiber scheint bereits installiert - überspringe Treiberinstallation."
elif [ "$OS_ID" = "ubuntu" ]; then
    sudo add-apt-repository ppa:graphics-drivers/ppa -y
    apt_update_once
    $PM_INSTALL nvidia-driver-590-open
elif [ "$OS_ID" = "rocky" ]; then
    # Use curl instead of dnf config-manager --add-repo (syntax changed in DNF5/Rocky 10)
    sudo curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/rhel${RHEL_MAJOR}/x86_64/cuda-rhel${RHEL_MAJOR}.repo" \
        -o "/etc/yum.repos.d/cuda-rhel${RHEL_MAJOR}.repo"
    apt_update_once
    $PM_INSTALL nvidia-open
fi

# AUTOFS (MOUNTS) MIT VALIDIERUNG ---
echo "Konfiguriere Autofs..."

sudo mkdir -p /mnt/houdini /mnt/nuke /mnt/studio /mnt/DeadlineRepository10

# Master Config
AUTOFS_CHANGED=0
if write_root_file_if_changed "/etc/auto.master" <<EOF
/mnt /etc/$AUTOFS_MAP_NAME --timeout=600 --ghost
EOF
then
    AUTOFS_CHANGED=1
    echo "/etc/auto.master aktualisiert."
fi

# Map Config
if write_root_file_if_changed "/etc/$AUTOFS_MAP_NAME" <<EOF
studio -fstype=cifs,rw,noperm,username=$STUDIO_USER,password=$STUDIO_PASS ://$SETUP_NAS_IP/studio
DeadlineRepository10 -fstype=cifs,rw,noperm,nounix,sec=ntlmssp,user=deadline,password=$DEADLINE_PASS ://$SETUP_DEADLINE_IP/DeadlineRepository10
houdini -fstype=cifs,rw,noperm,username=$WORKSTATION_SMB_USER,password=$WORKSTATION_PASS ://$SETUP_WORKSTATION_HOST/houdini
nuke -fstype=cifs,rw,noperm,username=$WORKSTATION_SMB_USER,password=$WORKSTATION_PASS ://$SETUP_WORKSTATION_HOST/nuke

EOF
then
    AUTOFS_CHANGED=1
    echo "/etc/$AUTOFS_MAP_NAME aktualisiert."
fi

# Autofs Neustart und Aktivierung
sudo systemctl enable --now autofs
if [ "$AUTOFS_CHANGED" -eq 1 ]; then
    sudo systemctl restart autofs
else
    echo "Autofs-Konfiguration unverändert - kein Neustart nötig."
fi

# MOUNT CHECK ---
echo "Prüfe Mounts (das kann 5-10 Sek. dauern)..."
sleep 5

# Funktion zum Testen
check_mount() {
    if ls "$1" >/dev/null 2>&1; then
        echo -e "\e[32m[OK]\e[0m Mount $1 ist aktiv."
    else
        echo -e "\e[31m[FEHLER]\e[0m Mount $1 konnte nicht geladen werden!"
        echo "Check: 'sudo journalctl -u autofs' für Details."
        # Optional: Hier abbrechen, da Houdini/Deadline ohne Mounts keinen Sinn ergeben
        # exit 1 
    fi
}

check_mount "/mnt/studio"
check_mount "/mnt/DeadlineRepository10"

# HOUDINI
INSTALL_DIR="$HOME/houdini_installer"
HOUDINI_INSTALLED=0

# Detect an existing Houdini installation so reruns are safe.
if compgen -G "/opt/hfs*/bin/houdini" > /dev/null; then
    HOUDINI_INSTALLED=1
fi

echo "Suche neueste Houdini Version in:"
echo "$SEARCH_DIR_HOUDINI"
echo "--------------------------------------"

if step_done "houdini_install" || [ "$HOUDINI_INSTALLED" -eq 1 ]; then
    echo "Houdini ist bereits installiert - überspringe Installation."
    mark_step_done "houdini_install"
else
    LATEST_TAR=$(ls -1 "$SEARCH_DIR_HOUDINI"/houdini-*-linux_x86_64_gcc*.tar.gz 2>/dev/null | sort -V | tail -n 1 || true)

    if [ -z "$LATEST_TAR" ]; then
        echo "FEHLER: Keine Houdini Datei gefunden!"
        exit 1
    fi

    FILENAME_ONLY=$(basename "$LATEST_TAR")
    echo "Gefunden: $FILENAME_ONLY"

    echo ""
    echo "Bereinige alten Installer-Ordner..."
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit

    echo "Kopiere Datei (das kann dauern)..."
    cp "$SEARCH_DIR_HOUDINI/$FILENAME_ONLY" .

    echo "Entpacke Archiv..."
    tar -xf "$FILENAME_ONLY"

    cd houdini-*/

    echo "Starte Installer (Root-Rechte erforderlich)..."

    sudo ./houdini.install --auto-install --accept-EULA "$HOUDINI_EULA_DATE" --install-houdini --install-license --install-sidefxlabs --install-menus

    echo "Räume auf..."
    cd ~
    rm -rf "$INSTALL_DIR"

    echo "HOUDINI INSTALLATION ERFOLGREICH"
    mark_step_done "houdini_install"
fi

echo "Installieren Houdini Dependencies"
$PM_INSTALL $PKGS_HOUDINI

# HOUDINI LICENSE SERVER CONFIG (Localhost) ---
echo "Konfiguriere Houdini License Server..."

# Sicherstellen, dass der Server-Dienst gestartet und aktiv ist
if service_exists "sesinetd.service"; then
    sudo systemctl enable sesinetd
    sudo systemctl restart sesinetd
else
    echo "Hinweis: sesinetd service nicht gefunden - überspringe Service-Konfiguration."
fi

# Dem Client sagen, dass er auf dem localhost nach Lizenzen suchen soll
# Das erstellt/überschreibt die Datei /usr/lib/sesi/licenses.client
HFS_BIN_DIR=$(ls -1d /opt/hfs*/bin 2>/dev/null | sort -V | tail -n 1 || true)
if [ -n "$HFS_BIN_DIR" ] && [ -x "$HFS_BIN_DIR/hserver" ]; then
    sudo "$HFS_BIN_DIR/hserver" -S localhost
    echo "Lizenz-Server auf localhost gesetzt."
else
    echo "Hinweis: hserver nicht gefunden - überspringe Lizenzserver-Clientkonfiguration."
fi

#7. DEADLINE INSTALLATION (2 WORKER) ---
INSTALL_DIR_DEADLINE="$HOME/deadline_installer"
DEADLINE_INSTALLED=0

# Detect an existing Deadline client install so reruns are safe.
if [ -x "/opt/Thinkbox/Deadline10/bin/deadlinecommand" ]; then
    DEADLINE_INSTALLED=1
fi

echo "Suche neueste Deadline Version in: $SEARCH_DIR_DEADLINE"

if step_done "deadline_install" || [ "$DEADLINE_INSTALLED" -eq 1 ]; then
    echo "Deadline ist bereits installiert - überspringe Installation."
    mark_step_done "deadline_install"
else
    LATEST_DEADLINE_TAR=$(ls -1 "$SEARCH_DIR_DEADLINE"/Deadline-*-linux-installers.tar 2>/dev/null | sort -V | tail -n 1 || true)

    if [ -z "$LATEST_DEADLINE_TAR" ]; then
        echo "FEHLER: Keine Deadline Bundle-Datei gefunden!"
        echo "Gesucht in: $SEARCH_DIR_DEADLINE"
        exit 1
    fi

    DEADLINE_FILENAME=$(basename "$LATEST_DEADLINE_TAR")
    echo "Gefunden: $DEADLINE_FILENAME"

    echo "Bereinige Deadline Installer-Ordner..."
    rm -rf "$INSTALL_DIR_DEADLINE"
    mkdir -p "$INSTALL_DIR_DEADLINE"
    cd "$INSTALL_DIR_DEADLINE" || exit

    echo "Kopiere Deadline Installer (das kann dauern)..."
    cp "$SEARCH_DIR_DEADLINE/$DEADLINE_FILENAME" .

    echo "Entpacke Archiv..."
    tar -xf "$DEADLINE_FILENAME"

    echo "Suche Client Installer..."
    RUN_FILE=$(ls -1 DeadlineClient-*-linux-x64-installer.run */DeadlineClient-*-linux-x64-installer.run 2>/dev/null | head -n 1 || true)

    if [ -z "$RUN_FILE" ]; then
        echo "FEHLER: Konnte 'DeadlineClient-*.run' nicht im entpackten Paket finden!"
        exit 1
    fi

    chmod +x "$RUN_FILE"
    echo "Installer gefunden: $RUN_FILE"

    echo "Starte Deadline Installer (als Daemon User: $NODE_NAME)..."

    sudo "$RUN_FILE" \
        --mode unattended \
        --prefix "/opt/Thinkbox/Deadline10" \
        --connectiontype Direct \
        --repositorydir "/mnt/DeadlineRepository10" \
        --licensemode LicenseFree \
        --launcherdaemon true \
        --daemonuser $NODE_NAME \
        --slavestartup false

    echo "Räume auf..."
    cd ~
    rm -rf "$INSTALL_DIR_DEADLINE"

    echo "DEADLINE INSTALLATION ERFOLGREICH"
    mark_step_done "deadline_install"
fi

echo "Installiere Deadline Dependencies"
# libgdiplus was removed from Ubuntu 24.04 and is not in Rocky repos — add Mono project repo
if [ "$OS_ID" = "ubuntu" ] && [ "$OS_VERSION" = "24.04" ]; then
    sudo mkdir -p /etc/apt/keyrings
    sudo curl -fsSL https://download.mono-project.com/repo/xamarin.gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/mono.gpg
    echo "deb [signed-by=/etc/apt/keyrings/mono.gpg] https://download.mono-project.com/repo/ubuntu stable-focal main" \
        | sudo tee /etc/apt/sources.list.d/mono-official-stable.list
    APT_UPDATED=0   # force refresh — new repo must be in cache before install
    apt_update_once
elif [ "$OS_ID" = "rocky" ]; then
    sudo rpm --import https://download.mono-project.com/repo/xamarin.gpg
    sudo curl -fsSL "https://download.mono-project.com/repo/centos${RHEL_MAJOR}-stable.repo" \
        -o "/etc/yum.repos.d/mono-centos${RHEL_MAJOR}-stable.repo"
    apt_update_once
fi
$PM_INSTALL $PKGS_DEADLINE

DEADLINE_COMMAND_BIN="/opt/Thinkbox/Deadline10/bin/deadlinecommand"

if [ -x "$DEADLINE_COMMAND_BIN" ]; then
echo "Erstelle Deadline System Services"
DEADLINE_UNITS_CHANGED=0
if write_root_file_if_changed "/etc/systemd/system/deadline10launcher.service" <<EOF
[Unit]
Description=Deadline 10 Launcher Service
After=network.target autofs.service
Requires=autofs.service
[Service]
Environment=\"DEADLINE_LAUNCHER_LISTENING_IP=0.0.0.0\"
Environment=\"DEADLINE_REMOTE_ADMIN_ENABLED=True\"
Type=simple
Restart=always
RestartSec=10
User=$NODE_NAME
LimitNOFILE=200000
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 30); do ls /mnt/DeadlineRepository10 > /dev/null 2>&1 && exit 0; echo \"Waiting for repo mount... (\$i/30)\"; sleep 2; done; exit 1'
ExecStart=/usr/bin/bash -l -c \"/opt/Thinkbox/Deadline10/bin/deadlinelauncher -daemon -nogui\"
ExecStop=/opt/Thinkbox/Deadline10/bin/deadlinelauncher -shutdownall
SuccessExitStatus=143
[Install]
WantedBy=multi-user.target
EOF
then
    DEADLINE_UNITS_CHANGED=1
fi

# IP-FIX & AUTO-LOGIN ---
if write_root_file_if_changed "/opt/Thinkbox/Deadline10/bin/set_worker_ip.sh" 0755 <<EOF
#!/bin/bash
sleep 20
/opt/Thinkbox/Deadline10/bin/deadlinecommand -SetSlaveSetting ${NODE_NAME}-gpu1 SlaveHostMachineIPAddressOverride $NODE_IP
/opt/Thinkbox/Deadline10/bin/deadlinecommand -SetSlaveSetting ${NODE_NAME}-gpu2 SlaveHostMachineIPAddressOverride $NODE_IP
EOF
then
    DEADLINE_UNITS_CHANGED=1
fi

if write_root_file_if_changed "/etc/systemd/system/deadline-ip-fix.service" <<EOF
[Unit]
Description=Fix Deadline Worker IP Overrides
After=deadline10launcher.service
[Service]
Type=oneshot
User=$NODE_NAME
ExecStart=/opt/Thinkbox/Deadline10/bin/set_worker_ip.sh
[Install]
WantedBy=multi-user.target
EOF
then
    DEADLINE_UNITS_CHANGED=1
fi

if write_root_file_if_changed "/etc/systemd/system/deadline-worker@.service" <<EOF
[Unit]
Description=Deadline Worker %i
After=network-online.target autofs.service deadline10launcher.service
Wants=network-online.target autofs.service
[Service]
Type=simple
User=$NODE_NAME
Group=$NODE_NAME
LimitNOFILE=200000
ExecStart=/opt/Thinkbox/Deadline10/bin/deadlineworker -nogui -name %i
ExecStop=/opt/Thinkbox/Deadline10/bin/deadlineworker -shutdown -name %i
TimeoutStopSec=60
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
then
    DEADLINE_UNITS_CHANGED=1
fi

if [ "$DEADLINE_UNITS_CHANGED" -eq 1 ]; then
    sudo systemctl daemon-reload
fi

# Deadline Symlinks
sudo ln -sf /opt/Thinkbox/Deadline10/bin/deadlinecommand /usr/bin/deadlinecommand

# (Optional) Auch gleich den Worker verlinken, schadet nie
sudo ln -sf /opt/Thinkbox/Deadline10/bin/deadlineworker /usr/bin/deadlineworker

# Deadline JSON Houdini
# Derive user package dir from installed HFS version (e.g. /opt/hfs21.0.xxx/bin -> houdini21.0.xxx)
_HFS_VER=$(basename "$(dirname "${HFS_BIN_DIR:-/opt/hfs21.0/bin}")" | sed 's/^hfs/houdini/')
HOUDINI_PKG_DIR="${_HFS_VER:-houdini21.0}"
mkdir -p "$HOME/$HOUDINI_PKG_DIR/packages"
if write_user_file_if_changed "$HOME/$HOUDINI_PKG_DIR/packages/deadline.json" <<EOF
{
    "env": [
        {
            "HOUDINI_PATH": "/mnt/DeadlineRepository10/submission/Houdini/Client"
        },
        {
            "PYTHONPATH": "/mnt/DeadlineRepository10/submission/Houdini/Client"
        }
    ]
}
EOF
then
    echo "deadline.json aktualisiert."
else
    echo "deadline.json bereits aktuell."
fi
else
echo "Hinweis: Deadline nicht installiert - überspringe Deadline Service/Client-Konfiguration."
fi

echo "Starte Dashboard & Auto-Login Setup für $NODE_NAME"

# 1. TTY1 Auto-Login (agetty override)
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/
if write_root_file_if_changed "/etc/systemd/system/getty@tty1.service.d/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $NODE_NAME --noclear %I \$TERM
EOF
then
    sudo systemctl daemon-reload
fi
# falls \$NODE_NAME nicht dein Benutzername ist!

# 2. SSH Silence & Kernel Printk
touch ~/.hushlogin
if write_root_file_if_changed "/etc/sysctl.d/99-silence-console.conf" <<EOF
kernel.printk = 3 4 1 3
EOF
then
    sudo sysctl --system > /dev/null
fi

# SSH Konfiguration anpassen
if [ -f /etc/ssh/sshd_config ]; then
    sudo sed -i 's/^#\?PrintMotd.*/PrintMotd no/' /etc/ssh/sshd_config
    sudo sed -i 's/^#\?PrintLastLog.*/PrintLastLog no/' /etc/ssh/sshd_config
else
    echo "Hinweis: /etc/ssh/sshd_config nicht gefunden - SSH Tweaks übersprungen."
fi
# sudo systemctl restart sshd

# SSH Welcome Script ---
if write_root_file_if_changed "/usr/local/bin/render-welcome.sh" 0755 <<'EOF'
#!/bin/bash

NODE=$(hostname)
IP=$(hostname -I | awk '{print $1}')
UPTIME=$(uptime -p)
CPU_LOAD=$(cut -d' ' -f1-3 /proc/loadavg)

# GPU info
if command -v nvidia-smi &>/dev/null; then
    GPU_INFO=$(nvidia-smi --query-gpu=index,name,memory.used,memory.total,temperature.gpu,utilization.gpu \
        --format=csv,noheader,nounits 2>/dev/null)
else
    GPU_INFO="nvidia-smi not found"
fi

# Deadline launcher status
DL_STATUS=$(systemctl is-active deadline10launcher 2>/dev/null)
if [ "$DL_STATUS" = "active" ]; then
    DL_STATUS="\e[32m● active\e[0m"
else
    DL_STATUS="\e[31m● $DL_STATUS\e[0m"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║               RENDER NODE — Deadline 10 Worker                  ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
printf "  %-16s %s\n" "Hostname:"  "$NODE"
printf "  %-16s %s\n" "IP:"        "$IP"
printf "  %-16s %s\n" "Uptime:"    "$UPTIME"
printf "  %-16s %s\n" "CPU Load:"  "$CPU_LOAD"
echo ""
echo "  GPUs"
echo "  ─────────────────────────────────────────────────────────────────"
if command -v nvidia-smi &>/dev/null; then
    while IFS=',' read -r idx name mem_used mem_total temp util; do
        name=$(echo "$name" | xargs)
        printf "  GPU%-2s  %-35s %s/%s MB  %s°C  %s%% util\n" \
            "$idx" "$name" "$(echo $mem_used|xargs)" "$(echo $mem_total|xargs)" \
            "$(echo $temp|xargs)" "$(echo $util|xargs)"
    done <<< "$GPU_INFO"
else
    echo "  No NVIDIA GPUs detected"
fi
echo ""
echo "  Services"
echo "  ─────────────────────────────────────────────────────────────────"
printf "  %-30s " "deadline10launcher:"
echo -e "$DL_STATUS"

# Show each deadline worker service
for unit in $(systemctl list-units --type=service --state=loaded 'deadline-worker@*' \
    --no-legend --no-pager 2>/dev/null | awk '{print $1}'); do
    svc_status=$(systemctl is-active "$unit" 2>/dev/null)
    if [ "$svc_status" = "active" ]; then
        colored="\e[32m● active\e[0m"
    else
        colored="\e[31m● $svc_status\e[0m"
    fi
    printf "  %-30s " "$unit:"
    echo -e "$colored"
done

echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║  ADDING A NEW WORKER GPU                                     ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
echo "  ║                                                              ║"
echo "  ║  1. Register the new worker IP:                              ║"
echo "  ║     sudo nano /opt/Thinkbox/Deadline10/bin/set_worker_ip.sh  ║"
echo "  ║     → Add line:                                              ║"
echo "  ║       deadlinecommand -SetSlaveSetting <node>-gpu3 \         ║"
echo "  ║         SlaveHostMachineIPAddressOverride <NODE_IP>          ║"
echo "  ║                                                              ║"
echo "  ║  2. Enable and start the worker service:                     ║"
echo "  ║     sudo systemctl enable --now deadline-worker@gpu3         ║"
echo "  ║                                                              ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""
EOF
then
    echo "render-welcome.sh installiert."
fi

write_root_file_if_changed "/etc/profile.d/render-welcome.sh" 0644 <<'EOF'
#!/bin/bash
# Show render node status on SSH login
if [[ -n "$SSH_CONNECTION" ]]; then
    bash /usr/local/bin/render-welcome.sh
fi
EOF

# 3. .bashrc Dashboard Logik
if step_done "bashrc_dashboard"; then
    echo "Dashboard-Block in ~/.bashrc bereits gesetzt - überspringe."
else
    # Alten Block entfernen (verwendet den exakten Matcher)
    sed -i '/# RENDER NODE DASHBOARD START/,/# RENDER NODE DASHBOARD END/d' ~/.bashrc

    # OS-aware update alias
    if [ "$OS_ID" = "ubuntu" ]; then
        _UPDATE_CMD="sudo apt update && sudo apt full-upgrade -y"
    else
        _UPDATE_CMD="sudo dnf upgrade -y"
    fi

    # Neuen Block einfügen
    if [ "$TTY1_MODE" = "render_dashboard" ]; then
        cat <<BASHEOF >> ~/.bashrc
# RENDER NODE DASHBOARD START
alias update="${_UPDATE_CMD}"

if [[ "\$(tty)" == "/dev/tty1" ]]; then
    TERM_COLS=\$(tput cols)
    TERM_ROWS=\$(tput lines)

    RENDEL=(
        "██████╗ ███████╗███╗   ██╗██████╗ ███████╗██╗      ██╗"
        "██╔══██╗██╔════╝████╗  ██║██╔══██╗██╔════╝██║      ██║"
        "██████╔╝█████╗  ██╔██╗ ██║██║  ██║█████╗  ██║      ██║"
        "██╔══██╗██╔══╝  ██║╚██╗██║██║  ██║██╔══╝  ██║      ╚═╝"
        "██║  ██║███████╗██║ ╚████║██████╔╝███████╗███████╗  ██╗"
        "╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚══════╝  ╚═╝"
    )

    BANGS=(
        " ██╗ ██╗ ██╗ ██╗ ██╗ ██╗ ██╗ ██╗ ██╗ ██╗"
        " ╚═╝ ██║ ╚═╝ ╚═╝ ╚═╝ ██║ ╚═╝ ╚═╝ ╚═╝ ╚═╝"
        "     ██║         ╚═╝  ██║               "
        "     ╚═╝              ╚═╝               "
    )

    SUBTITLE="R E N D E R   F A R M   N O D E"
    DIVIDER="════════════════════════════════════════════════════════════════════════"
    NODE_LINE="NODE: \$(hostname)   |   STATUS: IDLE"
    PROMPT="[ R ] REBOOT       [ S ] SHUTDOWN"

    TOTAL_LINES=20
    START_ROW=\$(( (TERM_ROWS - TOTAL_LINES) / 2 ))

    pad() {
        local text="\$1"
        local color="\$2"
        local len=\${#text}
        local spaces=\$(( (TERM_COLS - len) / 2 ))
        printf "%\${spaces}s" ""
        echo -e "\${color}\${text}\e[0m"
    }

    clear
    for ((i=0; i<START_ROW; i++)); do echo; done

    for line in "\${RENDEL[@]}"; do pad "\$line" "\e[32m"; done
    echo
    for line in "\${BANGS[@]}"; do pad "\$line" "\e[31m"; done
    echo
    pad "\$SUBTITLE" "\e[32m"
    pad "\$DIVIDER" "\e[32m"
    pad "\$NODE_LINE" "\e[32m"
    echo
    pad "\$PROMPT" "\e[32m"
    echo

    while true; do
        read -r -n 1 key
        case "\$key" in
            r|R) sudo reboot ;;
            s|S) sudo shutdown now ;;
        esac
    done
fi
# RENDER NODE DASHBOARD END
BASHEOF
    else
        cat <<BASHEOF >> ~/.bashrc
# RENDER NODE DASHBOARD START
alias update="${_UPDATE_CMD}"

if [[ "\$(tty)" == "/dev/tty1" ]]; then
    clear
    echo -e "\n  Prüfe Mounts..."
    ls /mnt/studio > /dev/null 2>&1 && echo "  [OK] Studio-Mount aktiv" || echo "  [!!] Studio-Mount FEHLT"

    sleep 3
    setterm -cursor off
    clear
    export TERM=linux
    export NCURSES_NO_UTF8_ACS=1

    echo -e "\n  Starte Monitor (nvtop)..."
    nvtop

    setterm -cursor on
fi
# RENDER NODE DASHBOARD END
BASHEOF
    fi
    mark_step_done "bashrc_dashboard"
fi

echo "Houdini package config wurde aktualisiert."

# DEADLINE INI PATCH (vor dem ersten Start) ---
# Muss vor FINALE AKTIVIERUNG laufen, damit der Launcher direkt mit korrekten Einstellungen startet.
DEADLINE_INI="/var/lib/Thinkbox/Deadline10/deadline.ini"
if [ -f "$DEADLINE_INI" ]; then
    sudo sed -i 's/RemoteControl=Blocked/RemoteControl=NotBlocked/' "$DEADLINE_INI"
    sudo sed -i 's/LauncherListeningIPAddress=.*/LauncherListeningIPAddress=0.0.0.0/' "$DEADLINE_INI"
    echo "--- Verifying $DEADLINE_INI ---"
    grep -E "RemoteControl|LauncherListening" "$DEADLINE_INI" || true
else
    echo "Hinweis: $DEADLINE_INI nicht gefunden - überspringe INI Patch."
fi

# FINALE AKTIVIERUNG ---
# daemon-reload ensures systemd picks up any unit files written in this run.
sudo systemctl daemon-reload
if service_exists "deadline10launcher.service"; then
    sudo systemctl enable --now deadline10launcher
fi
if service_exists "deadline-ip-fix.service"; then
    sudo systemctl enable --now deadline-ip-fix.service
fi
if service_exists "deadline-worker@.service"; then
    sudo systemctl enable --now deadline-worker@gpu1
    sudo systemctl enable --now deadline-worker@gpu2
else
    echo "Hinweis: deadline-worker@.service nicht gefunden - überspringe Worker Enable."
fi

# render_ops wird VOR dem Entfernen von ${NODE_NAME}_cmds geschrieben — kein Sudo-Gap
if write_root_file_if_changed "/etc/sudoers.d/render_ops" 0440 <<EOF
# Erlaubt Wartung, Software-Installation und Power-Management ohne Passwort
$NODE_NAME ALL=(ALL) NOPASSWD: ALL
EOF
then
    echo "render_ops sudoers wurde aktualisiert."
else
    echo "render_ops sudoers war bereits aktuell."
fi

# Temporäre Setup-Rechte entfernen (render_ops ist jetzt aktiv)
if [ -n "$NODE_NAME" ]; then
    sudo rm -f /etc/sudoers.d/${NODE_NAME}_cmds
    sudo rm -f /etc/sudoers.d/${NODE_NAME}_bash
    echo "Sudo-Sonderrechte für $NODE_NAME wurden entfernt."
else
    echo "Fehler: $NODE_NAME nicht gesetzt, lösche nichts."
fi

echo "Permanently Removing Cloud-Init"
CLOUD_INIT_INSTALLED=0
if [ "$OS_ID" = "ubuntu" ] && dpkg -s cloud-init >/dev/null 2>&1; then
    CLOUD_INIT_INSTALLED=1
elif [ "$OS_ID" = "rocky" ] && rpm -q cloud-init >/dev/null 2>&1; then
    CLOUD_INIT_INSTALLED=1
fi
if [ "$CLOUD_INIT_INSTALLED" -eq 1 ]; then
    $PM_PURGE cloud-init
else
    echo "cloud-init ist bereits nicht installiert - überspringe Purge."
fi
if [ -d /etc/cloud/ ]; then
    sudo rm -rf /etc/cloud/
fi
if [ -d /var/lib/cloud/ ]; then
    sudo rm -rf /var/lib/cloud/
fi

# HARDWARE-PROOF ETHERNET ---
# Both Ubuntu (netplan) and Rocky (NetworkManager) match 'en*' so the correct
# interface is always picked regardless of GPU slot changes.
if [ "$OS_ID" = "ubuntu" ]; then
    echo "Cleaning up Old Netplan Files"

    if [ -f /etc/netplan/50-cloud-init.yaml ]; then
        sudo rm /etc/netplan/50-cloud-init.yaml
        echo "Deleted /etc/netplan/50-cloud-init.yaml"
    fi

    echo "Configuring Hardware-Proof Ethernet (netplan)"
    NETPLAN_CHANGED=0
    if write_root_file_if_changed "/etc/netplan/00-installer-config.yaml" 0600 <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    wired-interfaces:
      match:
        name: "en*"
      dhcp4: true
      optional: true
EOF
    then
        NETPLAN_CHANGED=1
    fi

    sudo chown root:root /etc/netplan/00-installer-config.yaml
    sudo chmod 600 /etc/netplan/00-installer-config.yaml

    if [ "$NETPLAN_CHANGED" -eq 1 ]; then
        sudo netplan apply
    else
        echo "Netplan unverändert - kein apply nötig."
    fi
    sudo systemctl mask systemd-networkd-wait-online.service
    echo "Done! Ethernet config controlled by 00-installer-config.yaml"

elif [ "$OS_ID" = "rocky" ]; then
    echo "Configuring Hardware-Proof Ethernet (NetworkManager)"

    # Remove any cloud-init generated NM connections that may conflict
    sudo rm -f /etc/NetworkManager/system-connections/cloud-init*.nmconnection

    # Write a stable NM keyfile matching any 'en*' interface — equivalent of netplan match.
    # A UUID is generated once on first run; subsequent runs detect no change and skip.
    if ! sudo test -f /etc/NetworkManager/system-connections/wired-dhcp.nmconnection; then
        NM_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
        sudo install -m 0600 /dev/null /etc/NetworkManager/system-connections/wired-dhcp.nmconnection
        sudo tee /etc/NetworkManager/system-connections/wired-dhcp.nmconnection > /dev/null <<EOF
[connection]
id=wired-dhcp
uuid=$NM_UUID
type=ethernet
autoconnect=yes
autoconnect-priority=-999

[match]
interface-name=en*

[ethernet]

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto
EOF
        sudo nmcli connection reload
        echo "wired-dhcp NetworkManager connection erstellt."
    else
        echo "wired-dhcp NetworkManager connection bereits vorhanden."
    fi
    sudo systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true
    echo "Done! Ethernet config controlled by wired-dhcp.nmconnection"
fi

echo "Cloud-init will no longer overwrite your settings."


echo "Pulse connectivity fixes applied. Port 17000 should now accept remote connections."
echo ""

# HELP FILE ---
cat > ~/help.txt <<EOF
================================================================================
  RENDER NODE SETUP — FILE REFERENCE
  Node: $NODE_NAME  |  IP: $NODE_IP  |  OS: $OS_ID $OS_VERSION
  Generated: $(date)
================================================================================

SUDO / ACCESS CONTROL
  /etc/sudoers.d/render_ops          NOPASSWD:ALL for $NODE_NAME (permanent)
  /etc/sudoers.d/apt-env             Preserve DEBIAN_FRONTEND through sudo (Ubuntu only)

AUTOFS / MOUNTS
  /etc/auto.master                   Autofs master map  (mount root: /mnt, timeout: 600s)
  /etc/$AUTOFS_MAP_NAME              CIFS mount map
    /mnt/studio                        → //$SETUP_NAS_IP/studio       (user: $STUDIO_USER)
    /mnt/DeadlineRepository10          → //$SETUP_DEADLINE_IP/DeadlineRepository10
    /mnt/houdini                       → //$SETUP_WORKSTATION_HOST/houdini
    /mnt/nuke                          → //$SETUP_WORKSTATION_HOST/nuke
  journalctl -u autofs               View autofs logs

SYSTEMD SERVICES
  /etc/systemd/system/wol.service                      Wake-on-LAN (NIC: $NIC)
  /etc/systemd/system/deadline10launcher.service        Deadline 10 Launcher
  /etc/systemd/system/deadline-ip-fix.service           IP override fix (runs after launcher)
  /etc/systemd/system/deadline-worker@.service          Worker template unit
    Active workers:
      deadline-worker@gpu1
      deadline-worker@gpu2
    Add GPU:
      sudo systemctl enable --now deadline-worker@gpu3
  /etc/systemd/system/getty@tty1.service.d/override.conf  TTY1 autologin ($NODE_NAME)

  Useful commands:
    systemctl status deadline10launcher
    systemctl status 'deadline-worker@*'
    journalctl -u deadline10launcher -f

DEADLINE 10
  /opt/Thinkbox/Deadline10/          Install prefix
  /opt/Thinkbox/Deadline10/bin/set_worker_ip.sh   IP override script (edit to add GPUs)
  /var/lib/Thinkbox/Deadline10/deadline.ini        Runtime config (RemoteControl, ListeningIP)
  /usr/bin/deadlinecommand           → symlink to Deadline10/bin/deadlinecommand
  /usr/bin/deadlineworker            → symlink to Deadline10/bin/deadlineworker

HOUDINI
  /opt/hfs*/                         Houdini install (version-stamped dir)
  ~/houdini*/packages/deadline.json  Deadline submission plugin path config
  /usr/lib/sesi/licenses.client      License server pointer (set to localhost)
  /usr/lib/sesi/hserver/hserver.ini  Hserver config (APIKey for online licensing)

  Licensing commands:
    sudo /usr/lib/sesi/sesictrl login
    sudo /usr/lib/sesi/sesictrl redeem
    sudo /usr/lib/sesi/sesictrl print-license

  Online licensing (SideFX.com):
    Create app at https://www.sidefx.com/oauth2/applications
    Client type: confidential  |  Auth type: authorization code  |  Redirect: http://localhost
    Edit: sudo nano /usr/lib/sesi/hserver/hserver.ini  → APIKey=<ID> <SECRET>

NETWORK
EOF

if [ "$OS_ID" = "ubuntu" ]; then
cat >> ~/help.txt <<EOF
  /etc/netplan/00-installer-config.yaml   (0600) Hardware-proof DHCP (matches en*)
    Apply changes: sudo netplan apply
EOF
elif [ "$OS_ID" = "rocky" ]; then
cat >> ~/help.txt <<EOF
  /etc/NetworkManager/system-connections/wired-dhcp.nmconnection  (0600) Hardware-proof DHCP (matches en*)
    Apply changes: sudo nmcli connection reload
  /etc/selinux/config                SELinux disabled (permanent — requires reboot)
  /etc/yum.repos.d/cuda-rhel${RHEL_MAJOR}.repo        NVIDIA CUDA repo
  /etc/yum.repos.d/mono-centos${RHEL_MAJOR}-stable.repo  Mono repo (libgdiplus for Deadline)
EOF
fi

cat >> ~/help.txt <<EOF

SSH / LOGIN
  ~/.hushlogin                       Suppresses last-login message
  /etc/ssh/sshd_config               PrintMotd no, PrintLastLog no
  /etc/sysctl.d/99-silence-console.conf  Kernel printk suppressed (level 3)
  /usr/local/bin/render-welcome.sh   SSH welcome screen (node info, GPU, services)
  /etc/profile.d/render-welcome.sh   Triggers welcome on SSH login (\$SSH_CONNECTION)

TTY1 DASHBOARD
  ~/.bashrc  (RENDER NODE DASHBOARD block)
    TTY1 mode: $TTY1_MODE
    Shows RENDELL logo + R=Reboot / S=Shutdown  (render_dashboard)
    or launches nvtop                            (nvtop / dual-boot mode)

MISC
  /var/tmp/render-node-setup.state   Idempotency state file (delete to re-run steps)
    Steps tracked: base_system_tools, console_setup, houdini_install,
                   deadline_install, bashrc_dashboard
  /etc/default/grub                  GRUB cmdline: quiet$([ "$OS_ID" = "ubuntu" ] && echo " splash") video=1280x720

================================================================================
EOF

echo "~/help.txt geschrieben."

echo "------------------------------------------------"
echo "IP: $NODE_IP | WoL auf Interface: $NIC"
echo "------------------------------------------------"
echo "Houdini Lizensierung:"
echo "sudo /usr/lib/sesi/sesictrl login"
echo "sudo /usr/lib/sesi/sesictrl redeem"
echo "------------------------------------------------"
echo "ALTERNATIVE: Online Licensing"
echo "API Key auf https://www.sidefx.com/oauth2/applications erstellen"
echo "Client type: confidental, Auth type: authorization codeset"
echo "Redirect uris: http://localhost"
echo "/opt/hfs21.0/bin/hserver -S https://www.sidefx.com/license/sesinetd"
echo "sudo nano /usr/lib/sesi/hserver/hserver.ini"
echo "APIKey=ID SECRET"
echo "sudo /usr/lib/sesi/sesictrl print-license"
echo "------------------------------------------------"
echo "Aktive Netzwerk-Interfaces:"
echo "$(ip a)"
echo "------------------------------------------------"
if [ "$OS_ID" = "ubuntu" ]; then
    echo "Ethernet config: nano /etc/netplan/00-installer-config.yaml"
elif [ "$OS_ID" = "rocky" ]; then
    echo "Ethernet config: nano /etc/NetworkManager/system-connections/wired-dhcp.nmconnection"
fi
echo "----------------------------------------------------"
