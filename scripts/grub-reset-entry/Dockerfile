FROM archlinux

# 1. Construire l'image docker contenant les outils :
#      docker build -t initramfs-generator
# 2. Exécuter les outils :
#      docker run -v /boot:/output initramfs-generator
# Le "contrat d'interface" est de fournir un répertoire dans lequel seront générés :
#  - le fichier :      grub/custom.cfg
#  - le noyau :        zfs-restore-vmlinuz
#  - l'image système : zfs-restore-initramfs.img

# ZFS est maintenu par la communauté des utilisateurs Archlinux.
# On ajoute un dépot pour éviter de compiler les outils et le module pour le noyau.
RUN echo '[archzfs]' >> /etc/pacman.conf \
 && echo 'Server = http://archzfs.com/$repo/x86_64' >> /etc/pacman.conf \
 && echo '[archzfs-kernels]' >> /etc/pacman.conf \
 && echo 'Server = http://end.re/$repo/' >> /etc/pacman.conf
RUN pacman-key --init \
 && pacman-key --recv-keys DDF7DB817396A49B2A2723F7403BD972F75D9D76\
 && pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76

RUN pacman -Syu --noconfirm \
 && pacman -Sy --noconfirm mkinitcpio zfs-utils zfs-linux-lts

# On bricole le script d'init original.
# "normalement", à un moment il monte la "vraie" partition racine du système,
# puis à la fin il change de racine vers cette partition.
# Pour cela il utilise une fonction dont le nom est défini dans une variable
# 'mount_handler' ← ceci est le point d'extention qu'on utilise.
# On change le nom de la fonction mount_handler et on la remplace par une
# fonction qui va restaurer nos snapshots ZFS.
RUN cp /usr/lib/initcpio/init /usr/lib/initcpio/init.original
RUN sed -i 's/^mount_handler=.*/mount_handler=restore_zfs_snapshots_then_poweroff/' /usr/lib/initcpio/init
ADD zfs-reset-function /tmp
RUN cat /tmp/zfs-reset-function >> /usr/lib/initcpio/init_functions

ADD grub-custom.cfg /
ADD mkinitcpio.conf /
ADD mkinitcpio.sh /

RUN mkdir /output
VOLUME /output

CMD /mkinitcpio.sh
