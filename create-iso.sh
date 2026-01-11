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

# Create the directory structure
mkdir -p bin sbin usr/bin usr/sbin

# Get list of all busybox applets and create symlinks
echo "Creating symlinks for all busybox applets..."
cd /build/initramfs
/build/initramfs/bin/busybox --list-full > /tmp/applet_list.txt

while read applet; do
    # Extract directory and name from full path
    dir=$(dirname "$applet")
    name=$(basename "$applet")
    
    # Create directory if it doesn't exist
    mkdir -p "$dir"
    
    # Create symlink - calculate relative path to busybox
    case "$dir" in
        /bin)
            ln -sf busybox "bin/$name"
            ;;
        /sbin)
            ln -sf ../bin/busybox "sbin/$name"
            ;;
        /usr/bin)
            ln -sf ../../bin/busybox "usr/bin/$name"
            ;;
        /usr/sbin)
            ln -sf ../../bin/busybox "usr/sbin/$name"
            ;;
        *)
            # Default to bin for unknown paths
            ln -sf busybox "bin/$name"
            ;;
    esac
done < /tmp/applet_list.txt

# Verify symlinks were created
echo "Verifying busybox symlinks..."
ls -la bin/ | head -20
echo ""
echo "Checking sbin/:"
ls -la sbin/ | head -10
if [ ! -L bin/ls ]; then
    echo "Error: Symlinks not created properly"
    exit 1
fi

echo "Busybox applets installed successfully ($(ls bin/ | wc -l) in bin/, $(ls sbin/ | wc -l) in sbin/)"
cd /build

echo "Downloading and installing custom binaries..."
cd /build/initramfs

# Create lib directories for shared libraries
mkdir -p lib/x86_64-linux-gnu lib64

# Copy essential libraries from the build container
echo "Copying essential shared libraries..."
cp /lib/x86_64-linux-gnu/libc.so.6 lib/x86_64-linux-gnu/
cp /lib/x86_64-linux-gnu/libm.so.6 lib/x86_64-linux-gnu/
cp /lib/x86_64-linux-gnu/libpthread.so.0 lib/x86_64-linux-gnu/
cp /lib/x86_64-linux-gnu/libdl.so.2 lib/x86_64-linux-gnu/
cp /lib/x86_64-linux-gnu/librt.so.1 lib/x86_64-linux-gnu/
cp /lib/x86_64-linux-gnu/libtinfo.so.6 lib/x86_64-linux-gnu/ 2>/dev/null || true
cp /lib/x86_64-linux-gnu/libncursesw.so.6 lib/x86_64-linux-gnu/ 2>/dev/null || true

# Copy the dynamic linker (critical!)
cp /lib64/ld-linux-x86-64.so.2 lib64/

# Download fastfetch (system info tool)
echo "Installing fastfetch..."
wget -q --show-progress "https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-amd64.tar.gz" -O /tmp/fastfetch.tar.gz
tar -xzf /tmp/fastfetch.tar.gz -C /tmp
cp /tmp/fastfetch-linux-amd64/usr/bin/fastfetch usr/bin/
chmod +x usr/bin/fastfetch
rm -rf /tmp/fastfetch.tar.gz /tmp/fastfetch-linux-amd64

echo "Downloading static curl binary..."
wget -q --show-progress "https://github.com/moparisthebest/static-curl/releases/latest/download/curl-amd64" -O /build/initramfs/usr/bin/curl
chmod +x /build/initramfs/usr/bin/curl

echo "Custom binaries installed successfully!"
cd /build

# Download and extract kernel modules for networking
echo "Downloading kernel modules for networking..."
mkdir -p lib/modules
wget -q --show-progress "http://ftp.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz" -O /tmp/debian-initrd.gz
cd /tmp
mkdir -p debian-initrd
cd debian-initrd
gunzip -c /tmp/debian-initrd.gz | cpio -idm
# Copy network-related kernel modules
if [ -d lib/modules ]; then
    echo "Copying network kernel modules..."
    mkdir -p /build/initramfs/lib/modules
    cp -r lib/modules/* /build/initramfs/lib/modules/ 2>/dev/null || true
    echo "Available kernel modules:"
    find /build/initramfs/lib/modules -name "*.ko" | grep -E "(e1000|8139|virtio|net)" | head -20
fi
cd /build/initramfs
rm -rf /tmp/debian-initrd /tmp/debian-initrd.gz

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

# Set PATH environment variable
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Load network modules using insmod with full paths
echo "Loading network modules..."
KVER=$(/bin/busybox uname -r)
MODDIR="/lib/modules/$KVER/kernel/drivers/net"

# Try to load common network drivers
for driver in ethernet/intel/e1000/e1000.ko \
              ethernet/intel/e1000e/e1000e.ko \
              ethernet/realtek/8139too.ko \
              ethernet/realtek/8139cp.ko \
              virtio_net.ko; do
    if [ -f "$MODDIR/$driver" ]; then
        echo "Loading $driver..."
        /bin/busybox insmod "$MODDIR/$driver" 2>/dev/null || true
    fi
done

# Also check for virtio in different location
if [ -f "/lib/modules/$KVER/kernel/drivers/virtio/virtio_net.ko" ]; then
    echo "Loading virtio_net..."
    /bin/busybox insmod /lib/modules/$KVER/kernel/drivers/virtio/virtio.ko 2>/dev/null || true
    /bin/busybox insmod /lib/modules/$KVER/kernel/drivers/virtio/virtio_ring.ko 2>/dev/null || true
    /bin/busybox insmod /lib/modules/$KVER/kernel/drivers/net/virtio_net.ko 2>/dev/null || true
fi

# Wait a moment for devices to appear
/bin/busybox sleep 2

# Bring up loopback
/bin/busybox ifconfig lo 127.0.0.1 up

# Try to bring up network interfaces with DHCP
echo "Detecting ethernet cards..."
echo "Available interfaces:"
ls /sys/class/net/

for iface in /sys/class/net/*; do
    iface=$(basename "$iface")
    [ "$iface" = "lo" ] && continue
    echo "Configuring interface: $iface"
    /bin/busybox ifconfig "$iface" up
    /bin/busybox udhcpc -i "$iface" -t 5 -n -s /bin/simple-dhcp.sh 2>&1 &
done

# Wait for DHCP
/bin/busybox sleep 3

# Display welcome message
/bin/busybox clear
/bin/busybox echo "========================================"
/bin/busybox echo "  Welcome to Protogenix!"
/bin/busybox echo "========================================"
/bin/busybox echo ""
/bin/busybox echo "Kernel: $(/bin/busybox uname -r)"
/bin/busybox echo "Architecture: $(/bin/busybox uname -m)"
/bin/busybox echo ""

# Start getty for login prompt
/bin/busybox setsid /bin/busybox cttyhack /bin/getty -n -l /bin/login 38400 tty1
echo "Console session ended, shutting down..."
exec /bin/busybox poweroff -f
INITEOF

chmod +x init

# Create a simple profile to set PATH on login
cat > etc/profile << 'PROFILEEOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PS1='\u@\h:\w\$ '
export HOME=~
PROFILEEOF

# Create .profile for root user
cat > root/.profile << 'ROOTPROFILEEOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PS1='root@protogenix:\w# '
export HOME=/root
ROOTPROFILEEOF

# Create .profile for protogen user
mkdir -p home/protogen
cat > home/protogen/.profile << 'PROTOGENPROFILEEOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PS1='protogen@protogenix:\w\$ '
export HOME=/home/protogen
PROTOGENPROFILEEOF

chown -R 1000:1000 home/protogen 2>/dev/null || true

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

# Generate password hashes (password: beep for both users)
echo "Generating password hashes..."
ROOT_PASS_HASH=$(openssl passwd -6 beep)
PROTOGEN_PASS_HASH=$(openssl passwd -6 beep)
echo "Password hashes generated"

# Create passwd file - both root and protogen users with working shells
cat > etc/passwd << 'PASSWDEOF'
root:x:0:0:root:/root:/bin/sh
protogen:x:1000:1000:Protogen User:/home/protogen:/bin/sh
PASSWDEOF

# Create group file
cat > etc/group << 'GROUPEOF'
root:x:0:
protogen:x:1000:
GROUPEOF

# Create shadow file with generated password hashes for both users
cat > etc/shadow << SHADOWEOF
root:${ROOT_PASS_HASH}:19000:0:99999:7:::
protogen:${PROTOGEN_PASS_HASH}:19000:0:99999:7:::
SHADOWEOF

chmod 640 etc/shadow

# Create default resolv.conf with fallback DNS servers
cat > etc/resolv.conf << 'RESOLVEOF'
# Default DNS servers (will be overwritten by DHCP)
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLVEOF

# Create login.defs
cat > etc/login.defs << 'LOGINDEFSEOF'
PASS_MAX_DAYS   99999
PASS_MIN_DAYS   0
PASS_WARN_AGE   7
UID_MIN         1000
UID_MAX         60000
GID_MIN         1000
GID_MAX         60000
CREATE_HOME     yes
LOGINDEFSEOF

cat > bin/simple-dhcp.sh << 'DHCPEOF'
#!/bin/busybox sh
# Configure IP address
[ -n "$ip" ] && /bin/busybox ifconfig $interface $ip netmask ${subnet:-255.255.255.0}

# Configure default gateway
[ -n "$router" ] && /bin/busybox route add default gw $router

# Configure DNS servers
if [ -n "$dns" ]; then
    echo "# Generated by udhcpc" > /etc/resolv.conf
    for nameserver in $dns; do
        echo "nameserver $nameserver" >> /etc/resolv.conf
    done
    echo "DNS configured: $dns"
fi
DHCPEOF

chmod +x bin/simple-dhcp.sh

# Set SUID bit on su to allow privilege escalation (4755)
chmod 4755 bin/su
echo "Set SUID bit on /bin/su (mode 4755)"

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