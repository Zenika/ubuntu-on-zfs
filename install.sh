#!/bin/bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

# List of supported environment variables
# TARGET_DISK path of the block device on which Ubuntu is to be installed (full disk).
#   e.g: /dev/disk/by-id/nvme-KXG50ZNV512G_NVMe_TOSHIBA_512GB_Z74B602VKQJS
# TARGET_HOSTNAME host name of the machine to be installed
#   e.g: laptop-1
# NETWORK_INTERFACE network interface to use for install
#   e.g: wlp2s0
# ROOT_PASSWORD root password

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Script must be executed with root privileges"
        exit 1
    fi
}

dependencies() {
    apt-add-repository universe
    apt install -y debootstrap gdisk zfs-initramfs
}

select_disk() {
    local disks
    local options
    if [ -z "$TARGET_DISK" ]; then
        shopt -s nullglob
        disks=(/dev/disk/by-id/*)
        shopt -u nullglob
        options=()
        
        for i in "${!disks[@]}"; do
            options+=("${disks[i]}")
            options+=("")
        done

        TARGET_DISK=$(whiptail --title "Disk to install to" --menu \
            "Choose the device to install to (full disk)" 20 78 ${#disks[@]} \
            "${options[@]}" \
            3>&1 1>&2 2>&3)
    fi
    echo "The chosen disk is: ${TARGET_DISK}"
}

format_disk() {
    sgdisk --zap-all "${TARGET_DISK}"
}

create_partitions() {
    sgdisk -n2:1M:+512M \
    -t2:EF00 \
    "${TARGET_DISK}"

    sgdisk -n3:0:+512M \
    -t3:BF01 \
    "${TARGET_DISK}"

    sgdisk -n4:0:0 \
    -t4:BF01 \
    "${TARGET_DISK}"
}

# In /dev/disk/by-id, symbolic links to new block devices are created asynchronously by udev.
# Let's wait for them to be ready.
wait_for_partitions() {
    local retry=10

    until [ -b "$TARGET_DISK-part3" ] \
        && [ -b "$TARGET_DISK-part4" ]; do
        if [ "$(((retry--)))" -eq 0 ]; then
            echo "Timeout waiting for partitions"
            exit 1
        fi
        echo "Waiting for partitions to be ready…"
        sleep 1
    done
}

create_zfs_pools() {

    zpool create -f -o ashift=12 \
      -d \
      -o feature@async_destroy=enabled \
      -o feature@bookmarks=enabled \
      -o feature@embedded_data=enabled \
      -o feature@empty_bpobj=enabled \
      -o feature@enabled_txg=enabled \
      -o feature@extensible_dataset=enabled \
      -o feature@filesystem_limits=enabled \
      -o feature@hole_birth=enabled \
      -o feature@large_blocks=enabled \
      -o feature@lz4_compress=enabled \
      -o feature@spacemap_histogram=enabled \
      -o feature@userobj_accounting=enabled \
      -O acltype=posixacl \
      -O canmount=off \
      -O compression=lz4 \
      -O devices=off \
      -O normalization=formD \
      -O relatime=on \
      -O xattr=sa \
      -O mountpoint=/ \
      -R /mnt \
      bpool \
      "${TARGET_DISK}-part3"

      zpool create -f -o ashift=12 \
      -O acltype=posixacl \
      -O canmount=off \
      -O compression=lz4 \
      -O dnodesize=auto \
      -O normalization=formD \
      -O relatime=on \
      -O xattr=sa \
      -O mountpoint=/ \
      -R /mnt \
      rpool \
      "${TARGET_DISK}-part4"
}

create_zfs_datasets() {
    zfs create -o canmount=off -o mountpoint=none rpool/ROOT
    zfs create -o canmount=off -o mountpoint=none bpool/BOOT

    zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/ubuntu
    zfs mount rpool/ROOT/ubuntu

    zfs create -o canmount=noauto -o mountpoint=/boot bpool/BOOT/ubuntu
    zfs mount bpool/BOOT/ubuntu
}

install_minimum_system() {
    debootstrap bionic /mnt
    zfs set devices=off rpool
}

configure_hostname() {
    if [ -z "$TARGET_HOSTNAME" ]; then
        TARGET_HOSTNAME=$(whiptail --inputbox \
            "Enter a host name for this machine" 8 78 "" \
            --title "Host name" 3>&1 1>&2 2>&3)
    fi

    echo "${TARGET_HOSTNAME}" > /mnt/etc/hostname
    echo "127.0.1.1       ${TARGET_HOSTNAME}" >> /mnt/etc/hosts
}

configure_network() {
    local links
    local options
    if [ -z "$NETWORK_INTERFACE" ]; then
        # TO IMPROVE
        mapfile -t links < <( ip route show | grep "default via " | awk -F " " '{print $5}' )
        if [ ${#links[@]} -eq 1 ]; then
            NETWORK_INTERFACE=${links[0]}
        elif [ ${#links[@]} -gt 1 ]; then
            for i in "${!links[@]}"; do
                options+=("${links[i]}")
                options+=("")
            done
            NETWORK_INTERFACE=$(whiptail --title "Network interface" --menu \
                "Choose the network interface to use for install" 20 78 ${#links[@]} \
                "${options[@]}" \
                3>&1 1>&2 2>&3)
        else
            echo "Unable to find a suitable network interface"
            exit 1
        fi
    fi

    mkdir -p /mnt/etc/netplan/

    cat <<EOT >> /mnt/etc/netplan/01-netcfg.yaml
network:
  version: 2
  ethernets:
  ${NETWORK_INTERFACE}:
    dhcp4: true
EOT
}

configure_apt_sources() {
    echo "deb http://security.ubuntu.com/ubuntu bionic-security main universe" >> /mnt/etc/apt/sources.list
    echo "deb http://archive.ubuntu.com/ubuntu bionic-updates main universe" >> /mnt/etc/apt/sources.list
}

set_root_password() {
    local firstTry
    local secondTry
    until [ ! -z "$ROOT_PASSWORD" ]; do
        firstTry=$(whiptail --passwordbox \
            "Enter password for root user" 8 78 "" \
            --title "Choose root password" 3>&1 1>&2 2>&3)
        secondTry=$(whiptail --passwordbox \
            "Confirm password for root user" 8 78 "" \
            --title "Choose root password" 3>&1 1>&2 2>&3)
        if [ "$firstTry" == "$secondTry" ]; then
            ROOT_PASSWORD=$firstTry
        fi
    done
}

prepare_for_chroot() {
    mount --rbind /dev  /mnt/dev
    mount --rbind /proc /mnt/proc
    mount --rbind /sys  /mnt/sys
    cp chroot-install.sh /mnt
}

chroot_install() {
    TARGET_DISK="$TARGET_DISK" ROOT_PASSWORD="$ROOT_PASSWORD" chroot /mnt /chroot-install.sh
}

clean_chroot() {
    rm /mnt/chroot-install.sh
}

unmount_all_filesystems() {
    mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
    zpool export -a
}

main() {
    check_root

    dependencies

    select_disk

    format_disk

    create_partitions

    wait_for_partitions

    create_zfs_pools

    create_zfs_datasets

    install_minimum_system

    configure_hostname

    configure_network

    configure_apt_sources

    set_root_password

    prepare_for_chroot

    chroot_install

    clean_chroot

    unmount_all_filesystems

    #reboot
}

main