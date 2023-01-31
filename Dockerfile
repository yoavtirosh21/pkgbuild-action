FROM archlinux:latest

COPY entrypoint.sh /entrypoint.sh
COPY pacman.conf /etc/pacman.conf

ENTRYPOINT ["/entrypoint.sh"]
