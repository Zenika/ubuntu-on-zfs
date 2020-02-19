# Menu Grub pour réinitialiser les PC

Brève description du bricolage réalisé.

## Grub

Grub fournit une suite d'outils pour mettre en place et configurer un programme de démarrage. Il peut faire beaucoup de choses (dont on n'a pas besoin) et peut sembler compliqué. En général on inscrit la configuration dans `/etc/grub.d` et on exécute un outil qui va compiler tous les éléments de configuration et les déposer dans la partition montée sur `/boot`.

Ici, pour aller au plus simple, on écrira directement la configuration dans `/boot/grub/custom.cfg`. Ce fichier est chargé par la configuration de grub fournie par Ubuntu.

Dans `grub-custom.cfg` on ajoute un sous-menu et quelques items pour éviter un reset malencontreux. Seule une entrée est intéressante, voir le commentaire.

## Génération de l'image système chargée

On utilise les outils Archlinux pour créer un initramfs qui exécute un script personnalisé afin de restaurer les snapshots ZFS des PC de formation.

Il y a un Dockerfile mais docker ne sert à rien d'autre que fournir un environnement pour utiliser les outils Archlinux.

On a :

- un fichier de configuration additionel pour grub afin d'ajouter une entrée "restauration" dans le menu de boot
- un fichier `zfs-reset-function` qui contient la déclaration d'une fonction chargée de restaurer les snapshots ZFS
- `mkinitcpio.conf` qui contient la configuration utilisée par les outils Archlinux pour générer notre image initramfs
- `mkinitcpio.sh`, la commande exécutée lors de l'instanciation du conteneur. Elle génère l'initramfs avec notre fonction de restauration.

## Utilisation

1. Construire l'image docker contenant les outils :

    docker build -t initramfs-generator

2. Exécuter les outils :

    docker run -v /boot:/output initramfs-generator

3. Mettre à jour le snapshot `bpool/BOOT/ubuntu@current` (sinon on perd notre menu item de restauration après la première restauration) :

    zfs destroy  bpool/BOOT/ubuntu@current
    zfs snapshot bpool/BOOT/ubuntu@current
