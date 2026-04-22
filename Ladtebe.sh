#!/bin/bash
# SHITSMELL LINUX DEPLOYMENT SCRIPT - REINFORCED V7 (ULTRA-STABLE BOOT)
set -eo pipefail

# --- 0. Pre-Flight ---
ui_banner() {
    clear
    gum style --foreground 39 --border double --margin "1 1" --padding "1 2" --align center \
        "Shitsmell Linux"
}

ui_banner
echo "Verifying network connectivity..."

if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    echo "No internet detected. Setting up connection..."
    NET_TYPE=$(gum choose "Ethernet (Already connected)" "Wi-Fi Scan")
    if [[ "$NET_TYPE" == "Wi-Fi Scan" ]]; then
        nmcli dev wifi rescan
        SSID=$(nmcli -t -f SSID dev wifi list | grep -v '^--' | grep . | sort -u | gum filter --placeholder "Select Wi-Fi Network")
        WIFI_PASS=$(gum input --password --placeholder "Enter Wi-Fi Password")
        nmcli dev wifi connect "$SSID" password "$WIFI_PASS" || { echo "Connection failed!"; exit 1; }
    fi
fi

ping -c 3 archlinux.org >/dev/null 2>&1 || { echo "ERROR: No internet."; exit 1; }

echo "Initializing environment..."
[[ ! -f /usr/bin/gum ]] && pacman -Sy --noconfirm gum reflector
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf

# --- 1. System Configuration & Validation ---
ui_banner
while true; do
    USERNAME=$(gum input --placeholder "Username")
    [[ -n "$USERNAME" ]] && break
    echo "Username cannot be empty."
done

while true; do
    PASS=$(gum input --password --placeholder "User Password")
    PASS_CONFIRM=$(gum input --password --placeholder "Confirm User Password")
    if [[ "$PASS" == "$PASS_CONFIRM" && -n "$PASS" ]]; then
        break
    fi
    echo "Passwords do not match or are empty. Try again."
done

ROOT_PASS=$(gum input --password --placeholder "Root Password (blank to sync with user)")
[[ -z "$ROOT_PASS" ]] && ROOT_PASS="$PASS"
HOSTNAME="shitsmell"

ui_banner
LOCALE=$(grep "UTF-8" /etc/locale.gen | sed 's/^#//' | awk '{print $1}' | gum filter --placeholder "Select Locale")
[[ -z "$LOCALE" ]] && LOCALE="en_US.UTF-8"
LOCALE_ESC="${LOCALE//./\\.}"

KBD_LAYOUT=$(localectl list-keymaps | gum filter --placeholder "Select Keyboard Layout")
[[ -z "$KBD_LAYOUT" ]] && KBD_LAYOUT="us"

TIMEZONE=$(timedatectl list-timezones | gum filter --placeholder "Select Timezone")
[[ -z "$TIMEZONE" ]] && TIMEZONE="UTC"

KERN_PKG=$(gum choose "linux-zen" "linux" "linux-lts")
FS_TYPE=$(gum choose "ext4" "btrfs" "xfs" "f2fs")

SWAP_STRATEGY=$(gum choose "Only ZRAM" "Only Swapfile" "Both" "None")
ZRAM_SIZE="0"
SWAPFILE_SIZE="0"

[[ "$SWAP_STRATEGY" == *"ZRAM"* || "$SWAP_STRATEGY" == "Both" ]] && ZRAM_SIZE=$(gum input --placeholder "ZRAM size in MB (e.g. 8192)")
[[ "$SWAP_STRATEGY" == *"Swapfile"* || "$SWAP_STRATEGY" == "Both" ]] && SWAPFILE_SIZE=$(gum input --placeholder "Swapfile size in GB (e.g. 16)")

DE_CHOICE=$(gum choose "KDE Plasma" "GNOME" "XFCE" "Cinnamon" "Budgie" "MATE" "LXQt")

# --- 2. Storage Strategy ---
ui_banner
DEVICE_INFO=$(lsblk -dno NAME,SIZE,MODEL | grep -v "loop" | gum filter --placeholder "Select target drive")
[[ -z "$DEVICE_INFO" ]] && { echo "No device selected. Exiting."; exit 1; }
DEVICE="/dev/$(echo $DEVICE_INFO | awk '{print $1}')"
STRATEGY=$(gum choose "Erase Disk" "Manual Partitioning" "Replace Partition")

if [[ "$STRATEGY" == "Erase Disk" ]]; then
    sgdisk -Z "$DEVICE"
    sgdisk -n 1:0:+2G -t 1:ef00 "$DEVICE"
    sgdisk -n 2:0:0 -t 2:8304 "$DEVICE"
    partprobe "$DEVICE" && sleep 2
    [[ "$DEVICE" == *"nvme"* || "$DEVICE" == *"mmcblk"* ]] && { P1="${DEVICE}p1"; P2="${DEVICE}p2"; } || { P1="${DEVICE}1"; P2="${DEVICE}2"; }
elif [[ "$STRATEGY" == "Manual Partitioning" ]]; then
    cfdisk "$DEVICE"
    partprobe "$DEVICE" && sleep 2
    P1=$(lsblk -lno NAME,TYPE "$DEVICE" | grep "part" | awk '{print "/dev/"$1}' | gum filter --placeholder "Select EFI Partition")
    P2=$(lsblk -lno NAME,TYPE "$DEVICE" | grep "part" | awk '{print "/dev/"$1}' | gum filter --placeholder "Select Root Partition")
else
    P1=$(lsblk -lno NAME,TYPE "$DEVICE" | grep "part" | awk '{print "/dev/"$1}' | gum filter --placeholder "Select EFI Partition")
    P2=$(lsblk -lno NAME,TYPE "$DEVICE" | grep "part" | awk '{print "/dev/"$1}' | gum filter --placeholder "Select Root Partition to REPLACE")
    gum style --foreground 196 "CAUTION: $P2 will be wiped. EFI at $P1 will be kept."
    gum confirm "Continue?" || exit 1
fi

[[ -z "$P1" || -z "$P2" ]] && { echo "Partitions not correctly identified. Exiting."; exit 1; }

# --- 3. Formatting & Mounting ---
[[ "$STRATEGY" != "Replace Partition" ]] && mkfs.fat -F32 "$P1"

case "$FS_TYPE" in
    "btrfs")
        mkfs.btrfs -f "$P2" && mount "$P2" /mnt
        btrfs subvolume create /mnt/@
        btrfs subvolume create /mnt/@home
        umount /mnt
        mount -o subvol=@,noatime,compress=zstd:3 "$P2" /mnt
        mkdir -p /mnt/home
        mount -o subvol=@home,noatime,compress=zstd:3 "$P2" /mnt/home
        ;;
    "xfs") mkfs.xfs -f "$P2" && mount "$P2" /mnt ;;
    "f2fs") mkfs.f2fs -f "$P2" && mount -o noatime "$P2" /mnt ;;
    "ext4") mkfs.ext4 -F "$P2" && mount "$P2" /mnt ;;
esac
mkdir -p /mnt/boot/efi
mount "$P1" /mnt/boot/efi

if [[ "$SWAPFILE_SIZE" != "0" ]]; then
    truncate -s 0 /mnt/swapfile
    [[ "$FS_TYPE" == "btrfs" ]] && chattr +C /mnt/swapfile
    fallocate -l "${SWAPFILE_SIZE}G" /mnt/swapfile && chmod 600 /mnt/swapfile && mkswap /mnt/swapfile
fi

# --- 4. Base Install ---
pacstrap -K /mnt base base-devel linux-firmware git fish sudo networkmanager $KERN_PKG ${KERN_PKG}-headers $(grep -q "GenuineIntel" /proc/cpuinfo && echo "intel-ucode" || echo "amd-ucode") bluez bluez-utils f2fs-tools xfsprogs grub efibootmgr
genfstab -U /mnt >> /mnt/etc/fstab
[[ "$SWAPFILE_SIZE" != "0" ]] && echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# --- 5. Chroot ---
export TIMEZONE LOCALE_ESC LOCALE KBD_LAYOUT HOSTNAME USERNAME PASS ROOT_PASS DE_CHOICE ZRAM_SIZE KERN_PKG P2 FS_TYPE

arch-chroot /mnt /bin/bash <<EOF
    set -eo pipefail
    
    pacman-key --init && pacman-key --populate archlinux
    sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf
    echo -e "[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
    pacman -Syu --noconfirm

    ln -sf /usr/share/zoneinfo/\$TIMEZONE /etc/localtime && hwclock --systohc
    sed -i "s/#\$LOCALE_ESC/\$LOCALE/" /etc/locale.gen && locale-gen
    echo "LANG=\$LOCALE" > /etc/locale.conf
    echo "KEYMAP=\$KBD_LAYOUT" > /etc/vconsole.conf
    echo "\$HOSTNAME" > /etc/hostname
    echo -e "127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\t\$HOSTNAME.localdomain\t\$HOSTNAME" > /etc/hosts
    
    useradd -m -G wheel -s /usr/bin/fish \$USERNAME
    printf '%s:%s\n' "\$USERNAME" "\$PASS" | chpasswd
    printf 'root:%s\n' "\$ROOT_PASS" | chpasswd
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-shadow && chmod 440 /etc/sudoers.d/10-shadow

    # --- CRITICAL: BOOTLOADER & INITRAMFS (MOVED TO TOP) ---
    echo "Installing GRUB..."
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    
    R_PARTUUID=\$(blkid -s PARTUUID -o value \$P2)
    [[ "\$FS_TYPE" == "btrfs" ]] && FLAGS="rootflags=subvol=@" || FLAGS=""
    
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"root=PARTUUID=\$R_PARTUUID \$FLAGS rw quiet\"|" /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
    mkinitcpio -P

    # --- DESKTOP ENVIRONMENT ---
    case "\$DE_CHOICE" in
        "KDE Plasma") pacman -S --noconfirm plasma-desktop sddm konsole dolphin plasma-nm bluedevil; DM="sddm" ;;
        "GNOME") pacman -S --noconfirm gnome gnome-tweaks gdm; DM="gdm" ;;
        "XFCE") pacman -S --noconfirm xfce4 xfce4-goodies sddm; DM="sddm" ;;
        "Cinnamon") pacman -S --noconfirm cinnamon sddm nemo; DM="sddm" ;;
        "Budgie") pacman -S --noconfirm budgie sddm; DM="sddm" ;;
        "MATE") pacman -S --noconfirm mate mate-extra sddm; DM="sddm" ;;
        "LXQt") pacman -S --noconfirm lxqt sddm; DM="sddm" ;;
    esac
    systemctl enable \$DM NetworkManager bluetooth

    # --- CACHYOS REPO SETUP ---
    echo "Configuring CachyOS repositories..."
    cd /tmp && curl -sSL https://mirror.cachyos.org/cachyos-repo.tar.xz -o cachyos-repo.tar.xz
    tar xf cachyos-repo.tar.xz && cd cachyos-repo && yes | ./cachyos-repo.sh || true
    
    pacman-key --init && pacman-key --populate archlinux cachyos
    pacman -Sy --noconfirm cachyos-keyring
    pacman -Rdd --noconfirm mesa 2>/dev/null || true
    pacman -Syu --noconfirm --needed chwd power-profiles-daemon zram-generator
    chwd -a || true
    systemctl enable power-profiles-daemon
    [[ "\$ZRAM_SIZE" != "0" ]] && echo -e "[zram0]\nzram-size = \$ZRAM_SIZE\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf

    # --- AUR & EXTRA SOFTWARE (Failure allowed) ---
    su - \$USERNAME -c "cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm" || true
    su - \$USERNAME -c "yay -S --noconfirm --needed steam mangohud micro fastfetch vacuumtube krita kitty kate gparted pipewire-pulse obsidian-bin discord zen-browser-bin heroic-games-launcher-bin onlyoffice-bin lact-bin atlauncher-bin faugus-launcher hytale-launcher-bin protontricks goverlay protonplus gpu-screen-recorder shelly-bin" || true

    # --- FLATPAK SETUP (Failure allowed) ---
    pacman -S --noconfirm flatpak
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
    flatpak remote-add --if-not-exists trinity https://trinity-flatpak.codeberg.page/com.trench.trinity.launcher.flatpakrepo || true
    flatpak install -y flathub com.usebottles.bottles com.dec05eba.gpu_screen_recorder || true
    flatpak install -y trinity com.trench.trinity.launcher || true

    [[ -f /usr/lib/systemd/system/lactd.service ]] && systemctl enable lactd

    mkdir -p /etc/skel/.config/fish
    echo -e "set -g fish_greeting\nfastfetch" > /etc/skel/.config/fish/config.fish
    mkdir -p /home/\$USERNAME/.config/fish
    cp /etc/skel/.config/fish/config.fish /home/\$USERNAME/.config/fish/config.fish
    chown -R \$USERNAME:\$USERNAME /home/\$USERNAME/.config/fish
EOF

ui_banner
gum style --foreground 46 "Shitsmell Linux deployment complete. Bootloader is locked in."
gum confirm "Reboot?" && reboot
#!/bin/bash
# SHITSMELL LINUX DEPLOYMENT SCRIPT - REINFORCED V7 (ULTRA-STABLE BOOT)
set -eo pipefail

# --- 0. Pre-Flight ---
ui_banner() {
    clear
    gum style --foreground 39 --border double --margin "1 1" --padding "1 2" --align center \
        "Shitsmell Linux"
}

ui_banner
echo "Verifying network connectivity..."

if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    echo "No internet detected. Setting up connection..."
    NET_TYPE=$(gum choose "Ethernet (Already connected)" "Wi-Fi Scan")
    if [[ "$NET_TYPE" == "Wi-Fi Scan" ]]; then
        nmcli dev wifi rescan
        SSID=$(nmcli -t -f SSID dev wifi list | grep -v '^--' | grep . | sort -u | gum filter --placeholder "Select Wi-Fi Network")
        WIFI_PASS=$(gum input --password --placeholder "Enter Wi-Fi Password")
        nmcli dev wifi connect "$SSID" password "$WIFI_PASS" || { echo "Connection failed!"; exit 1; }
    fi
fi

ping -c 3 archlinux.org >/dev/null 2>&1 || { echo "ERROR: No internet."; exit 1; }

echo "Initializing environment..."
[[ ! -f /usr/bin/gum ]] && pacman -Sy --noconfirm gum reflector
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf

# --- 1. System Configuration & Validation ---
ui_banner
while true; do
    USERNAME=$(gum input --placeholder "Username")
    [[ -n "$USERNAME" ]] && break
    echo "Username cannot be empty."
done

while true; do
    PASS=$(gum input --password --placeholder "User Password")
    PASS_CONFIRM=$(gum input --password --placeholder "Confirm User Password")
    if [[ "$PASS" == "$PASS_CONFIRM" && -n "$PASS" ]]; then
        break
    fi
    echo "Passwords do not match or are empty. Try again."
done

ROOT_PASS=$(gum input --password --placeholder "Root Password (blank to sync with user)")
[[ -z "$ROOT_PASS" ]] && ROOT_PASS="$PASS"
HOSTNAME="shitsmell"

ui_banner
LOCALE=$(grep "UTF-8" /etc/locale.gen | sed 's/^#//' | awk '{print $1}' | gum filter --placeholder "Select Locale")
[[ -z "$LOCALE" ]] && LOCALE="en_US.UTF-8"
LOCALE_ESC="${LOCALE//./\\.}"

KBD_LAYOUT=$(localectl list-keymaps | gum filter --placeholder "Select Keyboard Layout")
[[ -z "$KBD_LAYOUT" ]] && KBD_LAYOUT="us"

TIMEZONE=$(timedatectl list-timezones | gum filter --placeholder "Select Timezone")
[[ -z "$TIMEZONE" ]] && TIMEZONE="UTC"

KERN_PKG=$(gum choose "linux-zen" "linux" "linux-lts")
FS_TYPE=$(gum choose "ext4" "btrfs" "xfs" "f2fs")

SWAP_STRATEGY=$(gum choose "Only ZRAM" "Only Swapfile" "Both" "None")
ZRAM_SIZE="0"
SWAPFILE_SIZE="0"

[[ "$SWAP_STRATEGY" == *"ZRAM"* || "$SWAP_STRATEGY" == "Both" ]] && ZRAM_SIZE=$(gum input --placeholder "ZRAM size in MB (e.g. 8192)")
[[ "$SWAP_STRATEGY" == *"Swapfile"* || "$SWAP_STRATEGY" == "Both" ]] && SWAPFILE_SIZE=$(gum input --placeholder "Swapfile size in GB (e.g. 16)")

DE_CHOICE=$(gum choose "KDE Plasma" "GNOME" "XFCE" "Cinnamon" "Budgie" "MATE" "LXQt")

# --- 2. Storage Strategy ---
ui_banner
DEVICE_INFO=$(lsblk -dno NAME,SIZE,MODEL | grep -v "loop" | gum filter --placeholder "Select target drive")
[[ -z "$DEVICE_INFO" ]] && { echo "No device selected. Exiting."; exit 1; }
DEVICE="/dev/$(echo $DEVICE_INFO | awk '{print $1}')"
STRATEGY=$(gum choose "Erase Disk" "Manual Partitioning" "Replace Partition")

if [[ "$STRATEGY" == "Erase Disk" ]]; then
    sgdisk -Z "$DEVICE"
    sgdisk -n 1:0:+2G -t 1:ef00 "$DEVICE"
    sgdisk -n 2:0:0 -t 2:8304 "$DEVICE"
    partprobe "$DEVICE" && sleep 2
    [[ "$DEVICE" == *"nvme"* || "$DEVICE" == *"mmcblk"* ]] && { P1="${DEVICE}p1"; P2="${DEVICE}p2"; } || { P1="${DEVICE}1"; P2="${DEVICE}2"; }
elif [[ "$STRATEGY" == "Manual Partitioning" ]]; then
    cfdisk "$DEVICE"
    partprobe "$DEVICE" && sleep 2
    P1=$(lsblk -lno NAME,TYPE "$DEVICE" | grep "part" | awk '{print "/dev/"$1}' | gum filter --placeholder "Select EFI Partition")
    P2=$(lsblk -lno NAME,TYPE "$DEVICE" | grep "part" | awk '{print "/dev/"$1}' | gum filter --placeholder "Select Root Partition")
else
    P1=$(lsblk -lno NAME,TYPE "$DEVICE" | grep "part" | awk '{print "/dev/"$1}' | gum filter --placeholder "Select EFI Partition")
    P2=$(lsblk -lno NAME,TYPE "$DEVICE" | grep "part" | awk '{print "/dev/"$1}' | gum filter --placeholder "Select Root Partition to REPLACE")
    gum style --foreground 196 "CAUTION: $P2 will be wiped. EFI at $P1 will be kept."
    gum confirm "Continue?" || exit 1
fi

[[ -z "$P1" || -z "$P2" ]] && { echo "Partitions not correctly identified. Exiting."; exit 1; }

# --- 3. Formatting & Mounting ---
[[ "$STRATEGY" != "Replace Partition" ]] && mkfs.fat -F32 "$P1"

case "$FS_TYPE" in
    "btrfs")
        mkfs.btrfs -f "$P2" && mount "$P2" /mnt
        btrfs subvolume create /mnt/@
        btrfs subvolume create /mnt/@home
        umount /mnt
        mount -o subvol=@,noatime,compress=zstd:3 "$P2" /mnt
        mkdir -p /mnt/home
        mount -o subvol=@home,noatime,compress=zstd:3 "$P2" /mnt/home
        ;;
    "xfs") mkfs.xfs -f "$P2" && mount "$P2" /mnt ;;
    "f2fs") mkfs.f2fs -f "$P2" && mount -o noatime "$P2" /mnt ;;
    "ext4") mkfs.ext4 -F "$P2" && mount "$P2" /mnt ;;
esac
mkdir -p /mnt/boot/efi
mount "$P1" /mnt/boot/efi

if [[ "$SWAPFILE_SIZE" != "0" ]]; then
    truncate -s 0 /mnt/swapfile
    [[ "$FS_TYPE" == "btrfs" ]] && chattr +C /mnt/swapfile
    fallocate -l "${SWAPFILE_SIZE}G" /mnt/swapfile && chmod 600 /mnt/swapfile && mkswap /mnt/swapfile
fi

# --- 4. Base Install ---
pacstrap -K /mnt base base-devel linux-firmware git fish sudo networkmanager $KERN_PKG ${KERN_PKG}-headers $(grep -q "GenuineIntel" /proc/cpuinfo && echo "intel-ucode" || echo "amd-ucode") bluez bluez-utils f2fs-tools xfsprogs grub efibootmgr
genfstab -U /mnt >> /mnt/etc/fstab
[[ "$SWAPFILE_SIZE" != "0" ]] && echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# --- 5. Chroot ---
export TIMEZONE LOCALE_ESC LOCALE KBD_LAYOUT HOSTNAME USERNAME PASS ROOT_PASS DE_CHOICE ZRAM_SIZE KERN_PKG P2 FS_TYPE

arch-chroot /mnt /bin/bash <<EOF
    set -eo pipefail
    
    pacman-key --init && pacman-key --populate archlinux
    sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf
    echo -e "[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
    pacman -Syu --noconfirm

    ln -sf /usr/share/zoneinfo/\$TIMEZONE /etc/localtime && hwclock --systohc
    sed -i "s/#\$LOCALE_ESC/\$LOCALE/" /etc/locale.gen && locale-gen
    echo "LANG=\$LOCALE" > /etc/locale.conf
    echo "KEYMAP=\$KBD_LAYOUT" > /etc/vconsole.conf
    echo "\$HOSTNAME" > /etc/hostname
    echo -e "127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\t\$HOSTNAME.localdomain\t\$HOSTNAME" > /etc/hosts
    
    useradd -m -G wheel -s /usr/bin/fish \$USERNAME
    printf '%s:%s\n' "\$USERNAME" "\$PASS" | chpasswd
    printf 'root:%s\n' "\$ROOT_PASS" | chpasswd
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-shadow && chmod 440 /etc/sudoers.d/10-shadow

    # --- CRITICAL: BOOTLOADER & INITRAMFS (MOVED TO TOP) ---
    echo "Installing GRUB..."
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    
    R_PARTUUID=\$(blkid -s PARTUUID -o value \$P2)
    [[ "\$FS_TYPE" == "btrfs" ]] && FLAGS="rootflags=subvol=@" || FLAGS=""
    
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"root=PARTUUID=\$R_PARTUUID \$FLAGS rw quiet\"|" /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
    mkinitcpio -P

    # --- DESKTOP ENVIRONMENT ---
    case "\$DE_CHOICE" in
        "KDE Plasma") pacman -S --noconfirm plasma-desktop sddm konsole dolphin plasma-nm bluedevil; DM="sddm" ;;
        "GNOME") pacman -S --noconfirm gnome gnome-tweaks gdm; DM="gdm" ;;
        "XFCE") pacman -S --noconfirm xfce4 xfce4-goodies sddm; DM="sddm" ;;
        "Cinnamon") pacman -S --noconfirm cinnamon sddm nemo; DM="sddm" ;;
        "Budgie") pacman -S --noconfirm budgie sddm; DM="sddm" ;;
        "MATE") pacman -S --noconfirm mate mate-extra sddm; DM="sddm" ;;
        "LXQt") pacman -S --noconfirm lxqt sddm; DM="sddm" ;;
    esac
    systemctl enable \$DM NetworkManager bluetooth

    # --- CACHYOS REPO SETUP ---
    echo "Configuring CachyOS repositories..."
    cd /tmp && curl -sSL https://mirror.cachyos.org/cachyos-repo.tar.xz -o cachyos-repo.tar.xz
    tar xf cachyos-repo.tar.xz && cd cachyos-repo && yes | ./cachyos-repo.sh || true
    
    pacman-key --init && pacman-key --populate archlinux cachyos
    pacman -Sy --noconfirm cachyos-keyring
    pacman -Rdd --noconfirm mesa 2>/dev/null || true
    pacman -Syu --noconfirm --needed chwd power-profiles-daemon zram-generator
    chwd -a || true
    systemctl enable power-profiles-daemon
    [[ "\$ZRAM_SIZE" != "0" ]] && echo -e "[zram0]\nzram-size = \$ZRAM_SIZE\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf

    # --- AUR & EXTRA SOFTWARE (Failure allowed) ---
    su - \$USERNAME -c "cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm" || true
    su - \$USERNAME -c "yay -S --noconfirm --needed steam mangohud micro fastfetch vacuumtube krita kitty kate gparted pipewire-pulse obsidian-bin discord zen-browser-bin heroic-games-launcher-bin onlyoffice-bin lact-bin atlauncher-bin faugus-launcher hytale-launcher-bin protontricks goverlay protonplus gpu-screen-recorder shelly-bin" || true

    # --- FLATPAK SETUP (Failure allowed) ---
    pacman -S --noconfirm flatpak
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
    flatpak remote-add --if-not-exists trinity https://trinity-flatpak.codeberg.page/com.trench.trinity.launcher.flatpakrepo || true
    flatpak install -y flathub com.usebottles.bottles com.dec05eba.gpu_screen_recorder || true
    flatpak install -y trinity com.trench.trinity.launcher || true

    [[ -f /usr/lib/systemd/system/lactd.service ]] && systemctl enable lactd

    mkdir -p /etc/skel/.config/fish
    echo -e "set -g fish_greeting\nfastfetch" > /etc/skel/.config/fish/config.fish
    mkdir -p /home/\$USERNAME/.config/fish
    cp /etc/skel/.config/fish/config.fish /home/\$USERNAME/.config/fish/config.fish
    chown -R \$USERNAME:\$USERNAME /home/\$USERNAME/.config/fish
EOF

ui_banner
gum style --foreground 46 "Shitsmell Linux deployment complete. Bootloader is locked in."
gum confirm "Reboot?" && reboot

