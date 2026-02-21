#!/bin/bash
set -e

# Global variables
DISK="/dev/sda"
PASS="azerty123"
HOSTNAME="archexam"
DISK_SIZE=$(lsblk -dnbo SIZE $DISK | awk '{print int($1/1024/1024/1024)}')
RAM_SIZE=$(free -m | awk '/^Mem:/{print $2}')
CPU_COUNT=$(lscpu | grep '^CPU(s):' | awk '{print $2}')

#Init disk
sgdisk -Z $DISK 

echo "--- Vérification des spécifications système ---"

# UEFI verification
if [ ! -d "/sys/firmware/efi" ]; then
    echo "ERREUR: Le système n'est pas en mode UEFI !"
    exit 1
else
    echo "UEFI >> OK"
fi

if [ "$DISK_SIZE" -lt 75 ]; then
    echo "ERREUR: Le disque est trop petit ($DISK_SIZE Go). 80 Go minimum requis."
    exit 1
else
    echo "DISK space required >> OK"
fi

if [ "$RAM_SIZE" -lt 7500 ]; then
    echo "ERREUR: Pas assez de RAM ($RAM_SIZE Mo). 8 Go requis."
    exit 1
else
    echo "RAM space required >> OK"
fi

if [ "$CPU_COUNT" -lt 4 ]; then
    echo "ERREUR: Pas assez de processeurs ($CPU_COUNT). 4 minimum requis."
    exit 1
else
    echo "Enough CPUs >> OK"
fi

echo "--- Verifications Done ---"

# Partitionnement
sgdisk -n 1:0:+512M -t 1:ef00 $DISK
sgdisk -n 2:0:0 -t 2:8309 $DISK

# Chiffrement principal (Système) (éviter Argon2id)
echo -n "$PASS" | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 "${DISK}2" -
echo -n "$PASS" | cryptsetup open "${DISK}2" cryptlvm

# LVM
pvcreate /dev/mapper/cryptlvm
vgcreate vg0 /dev/mapper/cryptlvm

lvcreate -L 20G vg0 -n root
lvcreate -L 8G vg0 -n swap
lvcreate -L 5G vg0 -n partage 
lvcreate -L 15G vg0 -n vbox
lvcreate -L 10G vg0 -n secret 
lvcreate -l +100%FREE vg0 -n home

# Format
mkfs.fat -F32 "${DISK}1"
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/vg0/home
mkfs.ext4 /dev/vg0/partage
mkfs.ext4 /dev/vg0/vbox
mkswap /dev/vg0/swap

# Secret partition to a luks partition
echo -n "$PASS" | cryptsetup luksFormat --type luks2 /dev/vg0/secret -

# Mount
mount /dev/vg0/root /mnt
mkdir -p /mnt/{boot,home,partage,var/lib/virtualbox}
mount "${DISK}1" /mnt/boot
mount /dev/vg0/home /mnt/home
mount /dev/vg0/partage /mnt/partage
mount /dev/vg0/vbox /mnt/var/lib/virtualbox
swapon /dev/vg0/swap

#Pacman packages refresh
pacman -Syu --noconfirm

# Package installation
pacstrap -K /mnt \
  base \
  linux \
  linux-firmware \
  lvm2 \
  base-devel \
  networkmanager \
  grub \
  efibootmgr \
  xorg-server \
  i3-wm \
  i3status \
  dmenu \
  terminator \
  firefox \
  openssh \
  htop \
  git \
  virtualbox \
  virtualbox-host-modules-arch \
  vim \
  bash-completion \
  man-db \
  man-pages \
  texinfo

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Initramfs for LUKS/LVM
sed -i '/^HOOKS=(/c\HOOKS=(base udev autodetect modconf block keyboard keymap encrypt lvm2 filesystems fsck)' /mnt/etc/mkinitcpio.conf

# GRUB configuration
UUID_LUKS=$(blkid -s UUID -o value ${DISK}2)
sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /mnt/etc/default/grub
sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/c\GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=$UUID_LUKS:cryptlvm root=/dev/mapper/vg0-root lang=fr_FR.UTF-8 vconsole.keymap=fr loglevel=3 quiet\"" /mnt/etc/default/grub

# System configuration inside chroot
arch-chroot /mnt /bin/bash <<EOF
# 1. Time & Language
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
echo "fr_FR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf
echo "KEYMAP=fr" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname

# 2. Users & Groups
groupadd famille
useradd -m -G wheel,vboxusers,famille -s /bin/bash Enzo
useradd -m -G famille -s /bin/bash Fiston
echo "Enzo:$PASS" | chpasswd
echo "Fiston:$PASS" | chpasswd

# 3. Permissions partage
chown root:famille /partage
chmod 770 /partage

# 4. i3 Config
mkdir -p /home/Enzo/.config/i3
cat <<'I3CONFIG' > /home/Enzo/.config/i3/config
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

# 5. Boot
mkinitcpio -P
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# 6. Service réseau
systemctl enable NetworkManager
EOF

# REPORT
REPORT="/mnt/report.txt"
echo "<<<<< RENDU PARTIEL ARCH LINUX >>>>>" > $REPORT
echo "HOSTNAME: $HOSTNAME" >> $REPORT
echo -e "\n--- DISQUES ---" >> $REPORT
lsblk -f >> $REPORT
echo -e "\n--- PASSWD ---" >> $REPORT
cat /mnt/etc/passwd >> $REPORT
echo -e "\n--- GROUP ---" >> $REPORT
cat /mnt/etc/group >> $REPORT
echo -e "\n--- FSTAB ---" >> $REPORT
cat /mnt/etc/fstab >> $REPORT
echo -e "\n--- LOGS INSTALLATION (dernières lignes) ---" >> $REPORT
grep -i installed /mnt/var/log/pacman.log | tail -n 20 >> $REPORT

echo "<<<<< Installation terminée - Redémarrez et lancez 'startx' >>>>>"