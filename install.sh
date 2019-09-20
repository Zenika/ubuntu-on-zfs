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
    if [ -z $TARGET_DISK ]; then
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

create_zfs_pools() {
    zpool create -o ashift=12 \
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

      zpool create -o ashift=12 \
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
    if [ -z $TARGET_HOSTNAME ]; then
        TARGET_HOSTNAME=$(whiptail --inputbox \
            "How do you want to name this machine?" 8 78 "" \
            --title "Host name" 3>&1 1>&2 2>&3)
    fi

    echo "${TARGET_HOSTNAME}" > /mnt/etc/hostname
    echo "127.0.1.1       ${TARGET_HOSTNAME}" >> /mnt/etc/hosts
}

configure_network() {
    local links
    local options
    if [ -z $NETWORK_INTERFACE ]; then
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
    { \
        echo "network:"; \
        echo "  version: 2"; \
        echo "  ethernets:"; \
        echo "    ${NETWORK_INTERFACE}:"; \
        echo "      dhcp4: true"; \
    } >> /mnt/etc/netplan/01-netcfg.yaml
}

configure_apt_sources() {

    echo "deb http://security.ubuntu.com/ubuntu bionic-security main universe" >> /mnt/etc/apt/sources.list
    echo "deb http://archive.ubuntu.com/ubuntu bionic-updates main universe" >> /mnt/etc/apt/sources.list
}

main() {
    check_root

    dependencies

    select_disk

    format_disk

    create_partitions

    create_zfs_pools

    create_zfs_datasets

    install_minimum_system

    configure_hostname

    configure_network

    configure_apt_sources
}

main