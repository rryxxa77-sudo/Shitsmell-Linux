#!/bin/bash
# SHITSMELL LINUX DEPLOYMENT SCRIPT - FINAL REINFORCED (V14)
set -eo pipefail

# --- 0. Pre-Flight ---
ui_banner() {
    clear
    gum style --foreground 39 --border double --margin "1 1" --padding "1 2" --align center \
        "Shitsmell Linux"
}

ui_banner
if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    nmcli dev wifi rescan
    SSID=$(nmcli -t -f SSID dev wifi list | grep -v '^--' | grep . | sort -u | gum filter --placeholder "Select Wi-Fi")
    WIFI_PASS=$(gum input --password --placeholder "Enter Password")
    nmcli dev wifi connect "$SSID" password "$WIFI_PASS" || exit 1
fi

echo "Initializing environment..."
[[ ! -f /usr/bin/gum ]] && pacman -Sy --noconfirm gum reflector
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf

# --- 1. System Configuration & Selection ---
ui_banner
DEVICE_INFO=$(lsblk -dno NAME,SIZE,MODEL | grep -v "loop" | gum filter --placeholder "Select target drive")
DEVICE="/dev/$(echo $DEVICE_INFO | awk '{print $1}')"

while true; do
    USERNAME=$(gum input --placeholder "Username")
    [[ -n "$USERNAME" ]] && break
done

# STRICT PASSWORD VALIDATION
while true; do
    PASS=$(gum input --password --placeholder "User Password")
    CONFIRM=$(gum input --password --placeholder "Confirm User Password")
    [[ "$PASS" == "$CONFIRM" && -n "$PASS" ]] && break
    gum style --foreground 196 "PASSWORDS DO NOT MATCH. TRY AGAIN."
done

ROOT_PASS=$(gum input --password --placeholder "Root Password (blank to sync)")
[[ -z "$ROOT_PASS" ]] && ROOT_PASS="$PASS"

LOCALE=$(grep "UTF-8" /etc/locale.gen | sed 's/^#//' | awk '{print $1}' | gum filter --placeholder "Select Locale")
LOCALE_ESC="${LOCALE//./\\.}"
KBD_LAYOUT=$(localectl list-keymaps | gum filter --placeholder "Select Keyboard Layout")
TIMEZONE=$(timedatectl list-timezones | gum filter --placeholder "Select Timezone")

ZRAM_SIZE=$(gum input --placeholder "ZRAM size in MB (e.g. 8192, 0 to disable)")
[[ -z "$ZRAM_SIZE" ]] && ZRAM_SIZE="0"

KERN_PKG=$(gum choose "linux-zen" "linux" "linux-lts")
FS_TYPE=$(gum choose "ext4" "btrfs" "xfs" "f2fs")
DE_CHOICE=$(gum choose "KDE Plasma" "GNOME" "XFCE")

gum confirm "START DEPLOYMENT ON $DEVICE?" || exit 0

# --- 2. Storage & Mount ---
sgdisk -Z "$DEVICE"
sgdisk -n 1:0:+2G -t 1:ef00 "$DEVICE"
sgdisk -n 2:0:0 -t 2:8304 "$DEVICE"
partprobe "$DEVICE" && sleep 2
[[ "$DEVICE" == *"nvme"* || "$DEVICE" == *"mmcblk"* ]] && { P1="${DEVICE}p1"; P2="${DEVICE}p2"; } || { P1="${DEVICE}1"; P2="${DEVICE}2"; }

mkfs.fat -F32 "$P1"
case "$FS_TYPE" in
    "btrfs")
        mkfs.btrfs -f "$P2" && mount "$P2" /mnt
        btrfs subvol create /mnt/@ && btrfs subvol create /mnt/@home
        umount /mnt
        mount -o subvol=@,noatime,compress=zstd:3 "$P2" /mnt
        mkdir -p /mnt/home && mount -o subvol=@home,noatime,compress=zstd:3 "$P2" /mnt/home
        ;;
    "xfs") mkfs.xfs -f "$P2" && mount "$P2" /mnt ;;
    "f2fs") mkfs.f2fs -f "$P2" && mount -o noatime "$P2" /mnt ;;
    "ext4") mkfs.ext4 -F "$P2" && mount "$P2" /mnt ;;
esac
mkdir -p /mnt/boot/efi && mount "$P1" /mnt/boot/efi

# --- 3. Base Install ---
pacstrap -K /mnt base base-devel linux-firmware git fish sudo networkmanager $KERN_PKG ${KERN_PKG}-headers amd-ucode xfsprogs grub efibootmgr flatpak
genfstab -U /mnt >> /mnt/etc/fstab

# --- 4. Chroot ---
export USERNAME PASS ROOT_PASS DE_CHOICE KERN_PKG P2 FS_TYPE TIMEZONE LOCALE LOCALE_ESC KBD_LAYOUT ZRAM_SIZE

arch-chroot /mnt /bin/bash <<EOF
    set -eo pipefail
    pacman-key --init && pacman-key --populate archlinux
    sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf
    
    ln -sf /usr/share/zoneinfo/\$TIMEZONE /etc/localtime && hwclock --systohc
    sed -i "s/#\$LOCALE_ESC/\$LOCALE/" /etc/locale.gen && locale-gen
    echo "LANG=\$LOCALE" > /etc/locale.conf
    [[ -n "\$KBD_LAYOUT" ]] && echo "KEYMAP=\$KBD_LAYOUT" > /etc/vconsole.conf
    echo "shitsmell" > /etc/hostname
    
    useradd -m -G wheel -s /usr/bin/fish \$USERNAME
    printf '%s:%s\n' "\$USERNAME" "\$PASS" | chpasswd
    printf 'root:%s\n' "\$ROOT_PASS" | chpasswd
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-shadow

    # --- BOOTLOADER & INITRAMFS (HIGH PRIORITY) ---
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    R_PARTUUID=\$(blkid -s PARTUUID -o value \$P2)
    [[ "\$FS_TYPE" == "btrfs" ]] && FLAGS="rootflags=subvol=@" || FLAGS=""
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"root=PARTUUID=\$R_PARTUUID \$FLAGS rw quiet\"|" /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
    mkinitcpio -P

    # --- DESKTOP ---
    case "\$DE_CHOICE" in
        "KDE Plasma") pacman -S --noconfirm plasma-desktop sddm konsole dolphin plasma-nm bluedevil; systemctl enable sddm ;;
        "GNOME") pacman -S --noconfirm gnome gdm; systemctl enable gdm ;;
        "XFCE") pacman -S --noconfirm xfce4 sddm; systemctl enable sddm ;;
    esac
    systemctl enable NetworkManager bluetooth

    # --- CACHYOS REPO ---
    cd /tmp && curl -sSL https://mirror.cachyos.org/cachyos-repo.tar.xz -o cachyos-repo.tar.xz
    tar xf cachyos-repo.tar.xz && cd cachyos-repo && yes | ./cachyos-repo.sh || true
    pacman -Sy --noconfirm cachyos-keyring
    pacman -Rdd --noconfirm mesa 2>/dev/null || true
    pacman -Syu --noconfirm --needed power-profiles-daemon zram-generator
    systemctl enable power-profiles-daemon
    [[ "\$ZRAM_SIZE" != "0" ]] && echo -e "[zram0]\nzram-size = \$ZRAM_SIZE\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf

    # --- AUR (FIXED LOOP) ---
    echo "Installing yay..."
    sudo -u \$USERNAME bash -c "cd /tmp && rm -rf yay-bin && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm" || true
    
    AUR_LIST=(steam mangohud micro fastfetch vacuumtube krita kitty kate gparted pipewire-pulse obsidian-bin discord zen-browser-bin heroic-games-launcher-bin onlyoffice-bin lact-bin atlauncher-bin faugus-launcher hytale-launcher-bin protontricks goverlay protonplus gpu-screen-recorder shelly-bin)
    for pkg in "\${AUR_LIST[@]}"; do
        sudo -u \$USERNAME bash -c "yay -S --noconfirm --needed \$pkg" || echo "FAILED TO INSTALL \$pkg - SKIPPING"
    done

    # --- FLATPAK ---
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
    flatpak install -y flathub com.usebottles.bottles com.dec05eba.gpu_screen_recorder || true

    # --- CHWD AT THE VERY END ---
    echo "Running final hardware detection..."
    pacman -S --noconfirm chwd || true
    chwd -a || true
EOF

ui_banner
gum style --foreground 46 "DEPLOYMENT FINISHED. CHWD AND AUR PROCESSED. REBOOTING."
sleep 3
reboot

