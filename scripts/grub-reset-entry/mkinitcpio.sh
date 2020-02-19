#!/bin/bash

mkdir -p /output/grub
cp -v /grub-custom.cfg /output/grub/custom.cfg
cp -v /boot/vmlinuz-linux-lts /output/zfs-restore-vmlinuz
mkinitcpio -c /mkinitcpio.conf \
    -k /output/zfs-restore-vmlinuz \
    -g /output/zfs-restore-initramfs.img
