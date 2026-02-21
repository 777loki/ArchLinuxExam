#!/bin/bash

# Variables de base
DISK="/dev/sda"
HOSTNAME="arch-exam"
USER_COLL="collegue"
USER_SON="fiston"
PASS="azerty123"

echo "--- Préparation du disque (UEFI, LUKS, LVM) ---"

# 1. Partitionnement (EFI: 512M, Reste: LVM chiffré)
sgdisk -Z $DISK
sgdisk -n 1:0:+512M -t 1:ef00 $DISK
sgdisk -n 2:0:0 -t 2:8e00 $DISK

# 2. Chiffrement de la partition système
echo -n "$PASS" | cryptsetup luksFormat "${DISK}2" -
echo -n "$PASS" | cryptsetup open "${DISK}2" cryptlvm -

# 3. Configuration LVM
pvcreate /dev/mapper/cryptlvm
vgcreate vg_system /dev/mapper/cryptlvm

lvcreate -L 20G vg_system -n lv_root
lvcreate -L 8G vg_system -n lv_swap
lvcreate -L 15G vg_system -n lv_vbox     # Espace dédié VirtualBox
lvcreate -L 5G vg_system -n lv_memes     # Dossier partagé
lvcreate -L 10G vg_system -n lv_secret    # Volume secret (à monter à la main)
lvcreate -l +100%FREE vg_system -n lv_home

# 4. Formatage
mkfs.fat -F32 "${DISK}1"
mkfs.ext4 /dev/vg_system/lv_root
mkfs.ext4 /dev/vg_system/lv_home
mkfs.ext4 /dev/vg_system/lv_vbox
mkfs.ext4 /dev/vg_system/lv_memes
mkswap /dev/vg_system/lv_swap

# Chiffrement additionnel pour le volume de 10Go (point 6)
echo -n "$PASS" | cryptsetup luksFormat /dev/vg_system/lv_secret -
# On ne le monte pas, conformément à la demande.

# 5. Montage
mount /dev/vg_system/lv_root /mnt
mkdir -p /mnt/{boot,home,var/lib/virtualbox,srv/memes}
mount "${DISK}1" /mnt/boot
mount /dev/vg_system/lv_home /mnt/home
mount /dev/vg_system/lv_vbox /mnt/var/lib/virtualbox
mount /dev/vg_system/lv_memes /mnt/srv/memes
swapon /dev/vg_system/lv_swap

echo "--- Installation du système de base ---"
pacstrap /mnt base linux linux-firmware lvm2 vim networkmanager

genfstab -U /mnt >> /mnt/etc/fstab

# Script de configuration interne (chroot)
cat <<EOF > /mnt/setup_chroot.sh
#!/bin/bash
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
echo "fr_FR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf
echo "KEYMAP=fr-latin1" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname

# Configuration Initramfs pour LUKS & LVM
sed -i 's/block filesystems/block lvm2 encrypt filesystems/' /etc/mkinitcpio.conf
mkinitcpio -p linux

# Bootloader (GRUB)
pacman -S --noconfirm grub efibootmgr
sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="cryptdevice=UUID=$(blkid -s UUID -o value ${DISK}2):cryptlvm root=/dev/vg_system/lv_root quiet"|' /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Création des utilisateurs
groupadd memes
useradd -m -G wheel,vboxusers,memes -s /bin/bash $USER_COLL
useradd -m -G memes -s /bin/bash $USER_SON
echo "$USER_COLL:$PASS" | chpasswd
echo "$USER_SON:$PASS" | chpasswd
echo "root:$PASS" | chpasswd

# Droits pour le dossier de memes
chown :memes /srv/memes
chmod 770 /srv/memes

# Installation des outils demandés (i3, dev C, VirtualBox, Apps)
pacman -S --noconfirm xorg-server i3-wm i3status dmenu terminator \
                      gcc make gdb binutils \
                      firefox vlc htop git virtualbox virtualbox-host-modules-arch

systemctl enable NetworkManager
EOF

chmod +x /mnt/setup_chroot.sh
arch-chroot /mnt ./setup_chroot.sh
rm /mnt/setup_chroot.sh

umount -R /mnt
swapoff -a
echo "Installation terminée. Rebooter et retirer l'ISO."