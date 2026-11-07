#!/bin/sh
# mmdebstrap customize hook. $1 is the root of the armhf rootfs.
#
# Access policy: the image has no shared password and no authorized SSH keys.
#  - Serial console: root login without a password, because it needs physical access.
#  - SSH: keys only, none are preinstalled. Host keys are created on first boot, per board.
set -eu
R="$1"

echo de1soc >"$R/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tde1soc\n' >"$R/etc/hosts"
printf '/dev/mmcblk0p2\t/\text4\tdefaults,noatime\t0\t1\n' >"$R/etc/fstab"

mkdir -p "$R/etc/systemd/system/serial-getty@ttyS0.service.d"
cat >"$R/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 %I $TERM
EOF

mkdir -p "$R/etc/ssh/sshd_config.d"
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >"$R/etc/ssh/sshd_config.d/10-keys-only.conf"
rm -f "$R"/etc/ssh/ssh_host_*
cat >"$R/etc/systemd/system/ssh-hostkeys.service" <<'EOF'
[Unit]
Description=Create SSH host keys on first boot
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/ssh-hostkeys.service "$R/etc/systemd/system/multi-user.target.wants/ssh-hostkeys.service"

mkdir -p "$R/etc/systemd/network"
printf '[Match]\nName=eth*\n\n[Network]\nDHCP=yes\n' >"$R/etc/systemd/network/20-wired.network"
ln -sf /usr/lib/systemd/system/systemd-networkd.service "$R/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"

chmod 0755 "$R/usr/local/bin/stockfish"
chmod 0644 "$R"/usr/share/stockfish/*.nnue
# Files from the build's staging tree (tools/build-rootfs.sh) arrive with the builder's uid.
chown -R 0:0 "$R/usr/local/bin" "$R/usr/share/stockfish"
if [ -d "$R/usr/share/chess-npu" ]; then
    chown -R 0:0 "$R/usr/share/chess-npu" "$R/usr/lib/chess-npu" "$R/etc/systemd/system/chess-npu-selftest.service"
    ln -sf /etc/systemd/system/chess-npu-selftest.service \
        "$R/etc/systemd/system/multi-user.target.wants/chess-npu-selftest.service"
    mkdir -p "$R/var/log/chess-npu"
fi
# The image must not carry the machine identity of the build.
: >"$R/etc/machine-id"
