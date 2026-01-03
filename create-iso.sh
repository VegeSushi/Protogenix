#!/bin/bash
set -e

# Check if running inside container
if [ ! -f "/.dockerenv" ]; then
    echo "Error: This script must be run inside a Docker container"
    exit 1
fi

echo "Creating build directories..."
mkdir -p /build/iso/boot/isolinux
mkdir -p /build/initramfs/bin
mkdir -p /build/initramfs/sbin
mkdir -p /build/initramfs/usr/bin
mkdir -p /build/initramfs/usr/sbin

echo "Downloading precompiled Linux kernel..."
if ! wget --progress=bar:force "http://ftp.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux" -O vmlinuz 2>&1; then
    echo "Error: Failed to download kernel"
    exit 1
fi

if [ ! -f vmlinuz ] || [ ! -s vmlinuz ]; then
    echo "Error: Kernel file is missing or empty"
    exit 1
fi

cp vmlinuz /build/iso/boot/vmlinuz
echo "Kernel downloaded successfully"

echo "Downloading precompiled busybox..."
if ! wget --progress=bar:force "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" -O /build/initramfs/bin/busybox 2>&1; then
    echo "Error: Failed to download busybox"
    exit 1
fi

if [ ! -f /build/initramfs/bin/busybox ] || [ ! -s /build/initramfs/bin/busybox ]; then
    echo "Error: Busybox file is missing or empty"
    exit 1
fi

chmod +x /build/initramfs/bin/busybox
echo "Busybox downloaded successfully"

echo "Installing busybox applets..."
cd /build/initramfs

# Create all necessary symlinks manually for common commands
cd bin
for cmd in sh ash ls cat echo ps mount umount mkdir rmdir cp mv rm ln chmod chown grep sed awk cut sort uniq wc head tail find xargs which whoami id hostname uname df du free top kill killall reboot poweroff halt clear dmesg more less vi; do
    ln -sf busybox $cmd
done
cd ..

cd sbin
for cmd in init reboot poweroff halt ifconfig route; do
    ln -sf ../bin/busybox $cmd
done
cd ..

cd usr/bin
for cmd in dirname basename; do
    ln -sf ../../bin/busybox $cmd
done
cd /build/initramfs

# Verify symlinks were created
echo "Verifying busybox symlinks..."
ls -la bin/ | head -20
if [ ! -L bin/ls ]; then
    echo "Error: Symlinks not created properly"
    exit 1
fi

echo "Busybox applets installed successfully"
cd /build

echo "Creating initramfs structure..."
cd /build/initramfs
mkdir -p dev proc sys tmp etc lib usr/lib root

# Ensure sh symlink exists in bin
ln -sf busybox bin/sh

# Create init script at root - use explicit busybox path for shebang
cat > init << 'INITEOF'
#!/bin/busybox sh

# Mount essential filesystems
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev

# Create device nodes if they don't exist
[ -e /dev/console ] || /bin/busybox mknod -m 622 /dev/console c 5 1
[ -e /dev/tty ] || /bin/busybox mknod -m 666 /dev/tty c 5 0
[ -e /dev/tty0 ] || /bin/busybox mknod -m 620 /dev/tty0 c 4 0
[ -e /dev/null ] || /bin/busybox mknod -m 666 /dev/null c 1 3

# Set PATH environment variable
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Set hostname
/bin/busybox hostname protogenix

# Display welcome message
/bin/busybox clear
/bin/busybox echo "========================================"
/bin/busybox echo "  Welcome to Protogenix!"
/bin/busybox echo "========================================"
/bin/busybox echo ""
/bin/busybox echo "Kernel: $(/bin/busybox uname -r)"
/bin/busybox echo "Architecture: $(/bin/busybox uname -m)"
/bin/busybox echo ""
/bin/busybox echo "Type 'help' to see available commands"
/bin/busybox echo ""

# Start shell with proper terminal and environment
exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh -c 'export PATH=/bin:/sbin:/usr/bin:/usr/sbin; export PS1="protogenix:\w\$ "; export HOME=/root; exec /bin/sh'
INITEOF

chmod +x init

# Create a simple profile to set PATH on login
cat > etc/profile << 'PROFILEEOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PS1='protogenix:\w\$ '
export HOME=/root
PROFILEEOF

# Create .profile in root home directory
mkdir -p root
cat > root/.profile << 'ROOTPROFILEEOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PS1='protogenix:\w\$ '
export HOME=/root
ROOTPROFILEEOF

# Remove inittab - we're using a simple init script instead
# The init script will handle everything

# Create rcS startup script (not used but good to have)
mkdir -p etc/init.d
cat > etc/init.d/rcS << 'RCSEOF'
#!/bin/busybox sh
# This file is not currently used
RCSEOF

chmod +x etc/init.d/rcS

# Create fstab
cat > etc/fstab << 'FSTABEOF'
proc    /proc   proc    defaults    0   0
sysfs   /sys    sysfs   defaults    0   0
devtmpfs /dev   devtmpfs defaults   0   0
FSTABEOF

# Remove passwd/shadow files - not using login for simplicity

echo "Creating initramfs archive..."
find . | cpio -H newc -o | gzip > /build/iso/boot/initramfs.gz
cd /build

echo "Setting up bootloader..."
cp /usr/lib/ISOLINUX/isolinux.bin /build/iso/boot/isolinux/
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 /build/iso/boot/isolinux/

cat > /build/iso/boot/isolinux/isolinux.cfg << 'ISOLINUXEOF'
DEFAULT linux
PROMPT 0
TIMEOUT 50

LABEL linux
  KERNEL /boot/vmlinuz
  APPEND initrd=/boot/initramfs.gz quiet
ISOLINUXEOF

echo "Creating ISO image..."
xorriso -as mkisofs \
    -o /output/protogenix.iso \
    -b boot/isolinux/isolinux.bin \
    -c boot/isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -J -R -V "Protogenix" \
    /build/iso

echo "ISO created successfully: /output/protogenix.iso"
ls -lh /output/protogenix.iso

# Change ownership to match host user
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
    chown "$HOST_UID:$HOST_GID" /output/protogenix.iso
    echo "Changed ownership to UID:GID $HOST_UID:$HOST_GID"
fi