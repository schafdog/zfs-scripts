#!/bin/bash

# Enable contrib in /etc/apt/source.list
#
apt-get update
apt install --yes debootstrap gdisk zfsutils-linux || exit

if [ ! -e "$DISK" ] ; then
    echo "DISK is not set!"
    exit
fi

# restart
wipefs -a $DISK || exit 
sgdisk --zap-all $DISK || exit
# legacy boot
sgdisk -a1 -n1:24K:+1000K -t1:EF02 $DISK
# EFI
sgdisk     -n2:1M:+1G -t2:EF00 $DISK || exit
# boot,root,swap
sgdisk     -n3:0:+2G  -t3:BF01 $DISK || exit
sgdisk     -n4:0:-1G  -t4:BF00 $DISK || exit
sgdisk     -n5:-1G:0  -t5:8200 $DISK || exit
sleep 5

DISK_PART3_UUID=$(sgdisk -i3 $DISK |  grep "^Partition unique GUID:" | awk '{print tolower($4)}')
echo $DISK_PART3_UUID
DISK_PART3="/dev/disk/by-partuuid/${DISK_PART3_UUID}"
if [ ! -e ${DISK_PART3} ] ; then
    echo "DISK_PART3 is missing"
    exit
fi
# bool pool
zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -o compatibility=grub2 \
    -o cachefile=/etc/zfs/zpool.cache \
    -O devices=off \
    -O acltype=posixacl -O xattr=sa \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off -O mountpoint=/boot -R /mnt \
    bpool ${DISK_PART3} || exit

zpool status bpool
echo "continue..."
read

# Root pool

DISK_PART4_UUID=$(sgdisk -i4 $DISK |  grep "^Partition unique GUID:" | awk '{print tolower($4)}')
DISK_PART4="/dev/disk/by-partuuid/$DISK_PART4_UUID"
if [ ! -e ${DISK_PART4} ] ; then
    echo "DISK_PART4 is missing"
    exit
fi

zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off -O mountpoint=/ -R /mnt \
    rpool ${DISK_PART4} || exit

zpool status rpool

# Root and boot dataset
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT

zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/debian
zfs mount rpool/ROOT/debian

zfs create -o mountpoint=/boot bpool/BOOT/debian

# Datasets
zfs create                     rpool/home
zfs create                     rpool/export
zfs create -o mountpoint=/root rpool/home/root
chmod 700 /mnt/root
zfs create -o canmount=off     rpool/var
zfs create -o canmount=off     rpool/var/lib
zfs create                     rpool/var/log
zfs create                     rpool/var/spool
# Optional
zfs create -o com.sun:auto-snapshot=false rpool/var/cache
zfs create -o com.sun:auto-snapshot=false rpool/var/lib/nfs
zfs create -o com.sun:auto-snapshot=false rpool/var/tmp
chmod 1777 /mnt/var/tmp
# GUI
zfs create rpool/var/lib/AccountsService
zfs create rpool/var/lib/NetworkManager
# Docker
zfs create -o com.sun:auto-snapshot=false rpool/var/lib/docker
# Mail
zfs create rpool/var/mail
# Snap
zfs create rpool/var/snap
# www
zfs create rpool/var/www

# tmpfs
mkdir /mnt/run
mount -t tmpfs tmpfs /mnt/run
mkdir /mnt/run/lock

# Install minimal system
debootstrap bookworm /mnt


mkdir /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/

hostname zfs-server
hostname > /mnt/etc/hostname
vi /mnt/etc/hosts

ip addr show

cat <<EOF > /mnt/etc/network/interfaces.d/enp1s0
auto enp1s0
iface enp1s0 inet dhcp
EOF
# 

cat <<EOF > /mnt/etc/apt/sources.list
deb http://deb.debian.org/debian bookworm main contrib non-free-firmware non-free
deb-src http://deb.debian.org/debian bookworm main contrib non-free-firmware

deb http://deb.debian.org/debian-security bookworm-security main contrib non-free-firmware non-free
deb-src http://deb.debian.org/debian-security bookworm-security main contrib non-free-firmware

deb http://deb.debian.org/debian bookworm-updates main contrib non-free-firmware non-free
deb-src http://deb.debian.org/debian bookworm-updates main contrib no
EOF
# 

# bind LiveCD into /mnt and change root
mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys

cp debian-zfs-install-chroot.sh /mnt/root/
chroot /mnt /usr/bin/env DISK=$DISK bash --login
# continue with chroot script

# after chroot
mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | \
    xargs -i{} umount -lf {}
zpool export -a
