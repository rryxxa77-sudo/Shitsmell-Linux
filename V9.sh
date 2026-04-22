#!/bin/bash
# SHITSMELL LINUX DEPLOYMENT SCRIPT - REINFORCED V9 (FLATPAK & AUR FIX)
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
    nmcli dev wifi rescan
    SSID=$(nmcli -t -f SSID dev wifi list | grep -v '^--' | grep . | sort -u | gum filter --placeholder "Select Wi-Fi Network")
    WIFI_PASS=$(gum input --password --placeholder "Enter Wi-Fi Password")
    nmcli dev wifi connect "$SSID" password "$WIFI_PASS" || { echo "Connection failed!"; exit 1; }
fi

echo "Initializing environment..."
[[ ! -f /usr/bin/gum ]] && pacman -Sy --noconfirm gum reflector
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf

# --- 1. Config ---
USERNAME=$(gum input --placeholder "Username")
PASS=$(gum input --password --placeholder "User Password")
ROOT_PASS=$(gum input --password --placeholder "Root Password (blank to sync)")
[[ -z "$ROOT_PASS" ]] && ROOT_PASS="$PASS"
HOSTNAME="shitsmell"

KERN_PKG=$(gum choose "linux-zen" "linux" "linux-lts")
FS_TYPE=$(gum choose "ext4" "btrfs" "xfs" "f2fs")
DE_CHOICE=$(gum choose "KDE Plasma" "GNOME" "XFCE")

# --- 2. Storage ---
DEVICE_INFO=$(lsblk -dno NAME,SIZE,MODEL | grep -v "loop" | gum filter --placeholder "Select target drive")
DEVICE="/dev/$(echo $DEVICE_INFO | awk '{print $1}')"
sgdisk -Z "$DEVICE"
sgdisk -n 1:0:+2G -t 1:ef00 "$DEVICE"
sgdisk -n 2:0:0 -t 2:8304 "$DEVICE"
partprobe "$DEVICE" && sleep 2
[[ "$DEVICE" == *"nvme"* || "$DEVICE" == *"mmcblk"* ]] && { P1="${DEVICE}p1"; P2="${DEVICE}p2"; } || { P1="${DEVICE}1"; P2="${DEVICE}2"; }

# --- 3. Format & Mount ---
mkfs.fat -F32 "$P1"
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

# --- 4. Base Install ---
pacstrap -K /mnt base base-devel linux-firmware git fish sudo networkmanager $KERN_PKG ${KERN_PKG}-headers amd-ucode xfsprogs grub efibootmgr flatpak
genfstab -U /mnt >> /mnt/etc/fstab

# --- 5. Chroot ---
export USERNAME PASS ROOT_PASS DE_CHOICE KERN_PKG P2 FS_TYPE HOSTNAME

arch-chroot /mnt /bin/bash <<EOF
    set -eo pipefail
    
    pacman-key --init && pacman-key --populate archlinux
    sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 15/' /etc/pacman.conf
    
    ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime && hwclock --systohc
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    echo "\$HOSTNAME" > /etc/hostname
    
    useradd -m -G wheel -s /usr/bin/fish \$USERNAME
    printf '%s:%s\n' "\$USERNAME" "\$PASS" | chpasswd
    printf 'root:%s\n' "\$ROOT_PASS" | chpasswd
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-shadow

    # --- BOOTLOADER FIRST ---
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    R_PARTUUID=\$(blkid -s PARTUUID -o value \$P2)
    [[ "\$FS_TYPE" == "btrfs" ]] && FLAGS="rootflags=subvol=@" || FLAGS=""
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"root=PARTUUID=\$R_PARTUUID \$FLAGS rw quiet\"|" /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
    mkinitcpio -P

    # --- DESKTOP ---
    case "\$DE_CHOICE" in
        "KDE Plasma") pacman -S --noconfirm plasma-desktop sddm konsole dolphin plasma-nm; systemctl enable sddm ;;
        "GNOME") pacman -S --noconfirm gnome gdm; systemctl enable gdm ;;
        "XFCE") pacman -S --noconfirm xfce4 sddm; systemctl enable sddm ;;
    esac
    systemctl enable NetworkManager

    # --- CACHYOS REPO ---
    cd /tmp && curl -sSL https://mirror.cachyos.org/cachyos-repo.tar.xz -o cachyos-repo.tar.xz
    tar xf cachyos-repo.tar.xz && cd cachyos-repo && yes | ./cachyos-repo.sh || true
    pacman -Sy --noconfirm cachyos-keyring
    pacman -Rdd --noconfirm mesa 2>/dev/null || true
    pacman -Syu --noconfirm --needed power-profiles-daemon zram-generator || true

    # --- AUR (YAY) FIX ---
    echo "Building yay..."
    sudo -u \$USERNAME bash -c "cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm" || true
    
    echo "Installing AUR packages..."
    sudo -u \$USERNAME bash -c "yay -S --noconfirm --needed steam mangohud micro fastfetch vacuumtube krita kitty kate gparted pipewire-pulse obsidian-bin discord zen-browser-bin heroic-games-launcher-bin onlyoffice-bin lact-bin atlauncher-bin faugus-launcher hytale-launcher-bin protontricks goverlay protonplus gpu-screen-recorder shelly-bin" || true

    # --- FLATPAK (STEP BY STEP FIX) ---
    echo "Configuring Flatpaks..."
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
    flatpak remote-add --if-not-exists trinity https://trinity-flatpak.codeberg.page/com.trench.trinity.launcher.flatpakrepo || true
    
    # Install one by one to prevent total failure
    flatpak install -y flathub com.usebottles.bottles || true
    flatpak install -y flathub com.dec05eba.gpu_screen_recorder || true
    flatpak install -y trinity com.trench.trinity.launcher || true
    flatpak install -y flathub io.qt.qtwebengine.BaseApp//6.10 || true
    flatpak install -y flathub org.kde.Platform//6.10 || true

    # Driver Detection at the very end
    pacman -S --noconfirm chwd || true
    chwd -a || true
EOF

ui_banner
gum style --foreground 46 "Shitsmell Linux V9 complete. Rebooting..."
sleep 3
reboot

