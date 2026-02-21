#!/bin/bash
set -e

# Global variables
DISK="/dev/sda"
PASS="azerty123"
HOSTNAME="archexam"

# Export pour le chroot
export PASS
export HOSTNAME

# Récupération propre des specs
DISK_SIZE=$(lsblk -dnbo SIZE $DISK | awk '{print int($1/1024/1024/1024)}')
RAM_SIZE=$(free -m | awk '/^Mem:/{print $2}')
CPU_COUNT=$(lscpu | grep '^CPU(s):' | awk '{print $2}')

echo "--- Vérification des spécifications système ---"
[ -d "/sys/firmware/efi" ] && echo "UEFI >> OK" || { echo "PAS D'UEFI"; exit 1; }
[ "$DISK_SIZE" -ge 75 ] && echo "DISK >> OK" || exit 1
[ "$RAM_SIZE" -ge 7500 ] && echo "RAM >> OK" || exit 1
[ "$CPU_COUNT" -ge 4 ] && echo "CPU >> OK" || exit 1

# Init disk
sgdisk -Z $DISK 
sgdisk -n 1:0:+512M -t 1:ef00 $DISK
sgdisk -n 2:0:0 -t 2:8309 $DISK

# Chiffrement
echo -n "$PASS" | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 "${DISK}2" -
echo -n "$PASS" | cryptsetup open "${DISK}2" cryptlvm

# LVM
pvcreate /dev/mapper/cryptlvm
vgcreate vg0 /dev/mapper/cryptlvm
lvcreate -L 25G vg0 -n root
lvcreate -L 8G vg0 -n swap
lvcreate -L 5G vg0 -n partage 
lvcreate -L 10G vg0 -n vbox
lvcreate -L 10G vg0 -n secret 
lvcreate -l +100%FREE vg0 -n home

# Format
mkfs.fat -F32 "${DISK}1"
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/vg0/home
mkfs.ext4 /dev/vg0/partage
mkfs.ext4 /dev/vg0/vbox
mkswap /dev/vg0/swap

# Double chiffrement secret
echo -n "$PASS" | cryptsetup luksFormat --type luks2 /dev/vg0/secret -

# Mount
mount /dev/vg0/root /mnt
mkdir -p /mnt/{boot,home,partage,var/lib/virtualbox}
mount "${DISK}1" /mnt/boot
mount /dev/vg0/home /mnt/home
mount /dev/vg0/partage /mnt/partage
mount /dev/vg0/vbox /mnt/var/lib/virtualbox
swapon /dev/vg0/swap

# Installation
pacman -Syu --noconfirm
pacstrap -K /mnt base linux linux-firmware lvm2 base-devel networkmanager grub efibootmgr xorg-server i3-wm i3status dmenu terminator firefox openssh htop git virtualbox virtualbox-host-modules-arch vim bash-completion man-db man-pages texinfo

# FSTAB (Après pacstrap)
genfstab -U /mnt >> /mnt/etc/fstab

# Config Pre-chroot
sed -i '/^HOOKS=(/c\HOOKS=(base udev autodetect modconf block keyboard keymap encrypt lvm2 filesystems fsck)' /mnt/etc/mkinitcpio.conf
UUID_LUKS=$(blkid -s UUID -o value ${DISK}2)
sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /mnt/etc/default/grub
sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/c\GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=$UUID_LUKS:cryptlvm root=/dev/mapper/vg0-root lang=fr_FR.UTF-8 vconsole.keymap=fr quiet\"" /mnt/etc/default/grub

# Chroot
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
echo "fr_FR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf
echo "KEYMAP=fr" > /etc/vconsole.conf
echo "\$HOSTNAME" > /etc/hostname

# Users & Groups
groupadd famille
useradd -m -G wheel,vboxusers,famille -s /bin/bash Enzo
useradd -m -G famille -s /bin/bash Fiston
echo "Enzo:\$PASS" | chpasswd
echo "Fiston:\$PASS" | chpasswd

# Permissions (le dossier est déjà monté sur /partage dans le chroot)
chown root:famille /partage
chmod 770 /partage

# i3 Config
mkdir -p /home/Enzo/.config/i3
cat <<I3CONFIG > /home/Enzo/.config/i3/config
exec --no-startup-id setxkbmap fr
set \$mod Mod4
bindsym \$mod+Return exec terminator
bindsym \$mod+d exec dmenu_run
bindsym \$mod+Shift+q kill
bar {
    status_command i3status
}
I3CONFIG
chown -R Enzo:Enzo /home/Enzo/.config

# Boot
mkinitcpio -P
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
systemctl enable NetworkManager
EOF

# REPORT (C'est ici qu'on vérifie le boulot)
REPORT="/mnt/report.txt"
{
    echo "<<<<< RENDU PARTIEL ARCH LINUX >>>>>"
    echo "HOSTNAME: $HOSTNAME"
    echo -e "\n--- DISQUES ---"
    lsblk -f
    echo -e "\n--- PASSWD ---"
    cat /mnt/etc/passwd
    echo -e "\n--- FSTAB ---"
    cat /mnt/etc/fstab
} > "$REPORT"

echo "Installation TERMINEE !"