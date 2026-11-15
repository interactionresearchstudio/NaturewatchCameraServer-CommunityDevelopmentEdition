#!/usr/bin/env bash
# Boot-test a Raspberry Pi OS based image under QEMU.
#
# Usage: test_image_boot.sh <image.img> [timeout-seconds-per-board] [log-file]
#
# 1. Static checks on the first image copy: the boot partition must contain
#    the firmware/kernel/dtb files the supported boards need, and the rootfs
#    must contain the installed Naturewatch services.
# 2. Boot tests, one per emulated board:
#      raspi3ap -> Pi 3 A+ and Pi Zero 2 W (BCM2710A1 is the 3A+'s BCM2837B0
#                  silicon with more RAM; raspi3ap is the closest QEMU model)
#      raspi3b  -> Pi 3 B / B+
#      raspi4b  -> Pi 4
#    QEMU has no model for the Pi 5 (BCM2712), and the current base image is
#    32-bit armhf, which the Pi 5 does not support at all.
#
#    Each board boots its own copy of the image. Success is signalled two
#    ways: an injected one-shot systemd unit writes a marker file to the boot
#    partition when the system reaches multi-user.target, and SSH (enabled via
#    the image's standard ssh/userconf.txt first-boot mechanism) becomes
#    reachable through QEMU user-mode networking. Serial console output is
#    captured to the log for debugging, but recent Raspberry Pi OS kernels
#    produce no serial output under QEMU even when they boot fine.
#
# Note: the Naturewatch server itself cannot be exercised under QEMU because
# it needs real camera hardware and RPi.GPIO, so "boots to multi-user" is the
# bar here; hardware behaviour still needs a real device.
set -u

IMAGE="$(readlink -f "${1:?usage: test_image_boot.sh <image.img> [timeout-seconds-per-board] [log-file]}")"
TIMEOUT="${2:-600}"
LOG_BASE="${3:-qemu-boot}"
BOOT_MNT=/tmp/img-boot
ROOT_MNT=/tmp/img-root
MARKER=qemu-boot-ok
SSH_FWD_PORT=2222
# raspi3ap covers both the Pi 3 A+ and the Pi Zero 2 W.
BOARDS="raspi3ap raspi3b raspi4b"

if [ ! -f "$IMAGE" ]; then
    echo "FAIL: image not found: $IMAGE" >&2
    exit 1
fi
if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
    echo "FAIL: qemu-system-aarch64 is not installed" >&2
    exit 1
fi

LOOP=""
LOOPC=""
cleanup() {
    sudo umount "$ROOT_MNT" 2>/dev/null
    sudo umount "$BOOT_MNT" 2>/dev/null
    for dev in "$LOOP" "$LOOPC"; do
        if [ -n "$dev" ]; then
            sudo losetup -d "$dev" 2>/dev/null
        fi
    done
    return 0
}
trap cleanup EXIT

sudo mkdir -p "$BOOT_MNT" "$ROOT_MNT"

# --- Attach the pristine image and run static checks ------------------------
LOOP="$(sudo losetup -fP --show "$IMAGE")"
echo "Attached image to loop device: $LOOP"
sleep 2
lsblk "$LOOP" || true
if [ ! -e "${LOOP}p1" ] || [ ! -e "${LOOP}p2" ]; then
    echo "FAIL: expected two partitions on the image (boot + rootfs)" >&2
    exit 1
fi
sudo mount -o ro "${LOOP}p1" "$BOOT_MNT"
sudo mount -o ro "${LOOP}p2" "$ROOT_MNT"

echo "=== Static image checks ==="
fail=0

check_required() {
    if [ -e "$2" ]; then
        echo "OK      $1"
    else
        echo "MISSING $1"
        fail=1
    fi
}
check_warn() {
    if [ -e "$2" ]; then
        echo "OK      $1"
    else
        echo "WARN    $1 (not fatal)"
    fi
}

check_required "boot/config.txt" "$BOOT_MNT/config.txt"
check_required "boot/cmdline.txt" "$BOOT_MNT/cmdline.txt"
ls "$BOOT_MNT"/kernel*.img >/dev/null 2>&1 \
    && echo "OK      boot/kernel*.img" \
    || { echo "MISSING boot/kernel*.img"; fail=1; }
ls "$BOOT_MNT"/start*.elf >/dev/null 2>&1 \
    && echo "OK      boot/start*.elf" \
    || { echo "MISSING boot/start*.elf"; fail=1; }
ls "$BOOT_MNT"/fixup*.dat >/dev/null 2>&1 \
    && echo "OK      boot/fixup*.dat" \
    || { echo "MISSING boot/fixup*.dat"; fail=1; }
# Pi 3 A+/B/B+ and Pi Zero 2 W (BCM2710) and Pi 4 (BCM2711) in 32-bit mode
# all boot the LPAE kernel and their own device trees.
check_warn "boot/kernel7l.img" "$BOOT_MNT/kernel7l.img"
check_warn "boot/bcm2710-rpi-zero-2-w.dtb" "$BOOT_MNT/bcm2710-rpi-zero-2-w.dtb"
check_warn "boot/bcm2710-rpi-zero-2.dtb" "$BOOT_MNT/bcm2710-rpi-zero-2.dtb"
check_warn "boot/bcm2710-rpi-3-b.dtb" "$BOOT_MNT/bcm2710-rpi-3-b.dtb"
check_warn "boot/bcm2711-rpi-4-b.dtb" "$BOOT_MNT/bcm2711-rpi-4-b.dtb"

check_required "rootfs/etc/os-release" "$ROOT_MNT/etc/os-release"
check_required "rootfs python.naturewatch.service" "$ROOT_MNT/etc/systemd/system/python.naturewatch.service"
check_required "rootfs wifisetup.service" "$ROOT_MNT/etc/systemd/system/wifisetup.service"
check_required "rootfs server venv" "$ROOT_MNT/usr/local/src/NaturewatchCameraServer/.venv/bin/python"

if [ "$fail" -ne 0 ]; then
    echo "FAIL: static checks failed"
    exit 1
fi
echo "All static checks passed."

KERNEL=""
for candidate in kernel7l.img kernel7.img; do
    if [ -e "$BOOT_MNT/$candidate" ]; then
        KERNEL="$candidate"
        break
    fi
done
if [ -z "$KERNEL" ]; then
    echo "FAIL: no 32-bit kernel (kernel7l.img/kernel7.img) in boot partition" >&2
    exit 1
fi
INITRD=""
case "$KERNEL" in
    kernel7l.img) [ -e "$BOOT_MNT/initramfs7l" ] && INITRD=initramfs7l ;;
    kernel7.img)  [ -e "$BOOT_MNT/initramfs7" ] && INITRD=initramfs7 ;;
esac
echo "Using kernel: $KERNEL (initramfs: ${INITRD:-none})"

# Keep the image's own root=, rootfstype and fsck arguments, but drop the
# first-boot init= handler (it runs as PID 1 instead of systemd, never reaches
# multi-user, and ends with `reboot -f`, which would kill QEMU; the image's
# root partition is already resized during the build) and the console= entries
# so QEMU's serial device is used deterministically. The ssh and userconf.txt
# first-boot markers are processed by their normal systemd services instead.
CMDLINE="$(tr -d '\n' < "$BOOT_MNT/cmdline.txt")"
APPEND=""
for tok in $CMDLINE; do
    case "$tok" in
        console=*|init=*|quiet) ;;
        *) APPEND="$APPEND $tok" ;;
    esac
done
APPEND="rw console=ttyAMA0,115200 console=ttyS0,115200$APPEND"
echo "Kernel command line:$APPEND"

sudo umount "$ROOT_MNT" "$BOOT_MNT"

# Copy the kernel and initramfs out; they are needed for every board boot and
# the partitions get remounted per board below.
KERNEL_PATH=/tmp/img-kernel
INITRD_PATH=/tmp/img-initramfs
sudo mount -o ro "${LOOP}p1" "$BOOT_MNT"
sudo cp "$BOOT_MNT/$KERNEL" "$KERNEL_PATH"
[ -n "$INITRD" ] && sudo cp "$BOOT_MNT/$INITRD" "$INITRD_PATH"
sudo chmod 644 "$KERNEL_PATH"
[ -n "$INITRD" ] && sudo chmod 644 "$INITRD_PATH"
sudo umount "$BOOT_MNT"

# --- Boot test per board ------------------------------------------------------
overall=0
for BOARD in $BOARDS; do
    echo ""
    echo "=== Boot test: $BOARD (timeout ${TIMEOUT}s) ==="
    COPY="/tmp/img-test-$BOARD.img"
    LOG="$LOG_BASE-$BOARD.log"
    rm -f "$COPY" "$LOG"
    cp "$IMAGE" "$COPY"

    LOOPC=""
    LOOPC="$(sudo losetup -fP --show "$COPY")"
    sleep 2

    # Enable SSH via the image's first-boot mechanism and drop any stale
    # marker from a previous run of the same copy.
    if ! sudo mount "${LOOPC}p1" "$BOOT_MNT"; then
        echo "RESULT $BOARD: FAIL (could not mount boot partition of the copy)"
        sudo losetup -d "$LOOPC" 2>/dev/null
        rm -f "$COPY"
        overall=1
        continue
    fi
    sudo rm -f "$BOOT_MNT/$MARKER"
    sudo touch "$BOOT_MNT/ssh"
    echo "pi:raspberry" | sudo tee "$BOOT_MNT/userconf.txt" >/dev/null

    # Inject the marker unit recording that multi-user.target was reached.
    if ! sudo mount "${LOOPC}p2" "$ROOT_MNT"; then
        echo "RESULT $BOARD: FAIL (could not mount rootfs of the copy)"
        sudo umount "$BOOT_MNT" 2>/dev/null
        sudo losetup -d "$LOOPC" 2>/dev/null
        rm -f "$COPY"
        overall=1
        continue
    fi
    sudo tee "$ROOT_MNT/etc/systemd/system/qemu-boot-marker.service" >/dev/null <<'EOF'
[Unit]
Description=QEMU boot test marker (written by test_image_boot.sh)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for d in /boot/firmware /boot; do [ -d "$d" ] && touch "$d/qemu-boot-ok" && break; done'

[Install]
WantedBy=multi-user.target
EOF
    sudo mkdir -p "$ROOT_MNT/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf /etc/systemd/system/qemu-boot-marker.service \
        "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/qemu-boot-marker.service"
    sudo umount "$ROOT_MNT" "$BOOT_MNT"
    # Detach now: a loop device whose pages were touched during injection
    # would serve stale cache reads later, after QEMU has written to the same
    # file behind its back.
    sudo losetup -d "$LOOPC"
    LOOPC=""

    # The Pi 3/4 class machines moved from qemu-system-arm to
    # qemu-system-aarch64 in newer QEMU releases, so use the 64-bit binary;
    # it boots 32-bit kernels fine. Memory is fixed per machine, so -m is
    # omitted. usb-net provides the network device the boards' real NICs
    # stand in for, with hostfwd for the SSH reachability probe.
    qemu-system-aarch64 \
        -M "$BOARD" -smp 4 \
        -kernel "$KERNEL_PATH" \
        ${INITRD:+-initrd "$INITRD_PATH"} \
        -drive file="$COPY",format=raw,if=sd \
        -append "$APPEND" \
        -display none -monitor none \
        -serial "file:$LOG" \
        -no-reboot \
        -device usb-net,netdev=net0 \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_FWD_PORT}-:22" &
    QPID=$!
    sleep 3
    if ! kill -0 "$QPID" 2>/dev/null; then
        echo "RESULT $BOARD: FAIL (qemu exited immediately)"
        sudo losetup -d "$LOOPC" 2>/dev/null
        rm -f "$COPY"
        overall=1
        continue
    fi

    SUCCESS_RE='login:'
    FAILURE_RE='Kernel panic|Emergency Mode|Give root password'
    RESULT=timeout
    deadline=$((SECONDS + TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! kill -0 "$QPID" 2>/dev/null; then
            RESULT=died
            break
        fi
        if grep -Eq "$FAILURE_RE" "$LOG" 2>/dev/null; then
            RESULT=panic
            break
        fi
        if grep -Eq "$SUCCESS_RE" "$LOG" 2>/dev/null; then
            RESULT=ok-serial
            break
        fi
        # sshd answering with its protocol banner means userspace is fully up.
        # A bare TCP connect is not enough: QEMU's hostfwd listener accepts the
        # host-side handshake itself before the guest is reachable.
        if timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${SSH_FWD_PORT} && head -c 4 <&3" 2>/dev/null | grep -q "SSH-"; then
            RESULT=ok-ssh
            break
        fi
        sleep 5
    done

    if kill -0 "$QPID" 2>/dev/null; then
        kill "$QPID" 2>/dev/null
        wait "$QPID" 2>/dev/null
    fi
    sleep 2

    # Final signal: the marker file written by the injected unit, read through
    # a freshly attached loop device so no stale cache hides it.
    if [ "$RESULT" = timeout ]; then
        LOOPC="$(sudo losetup -fP --show "$COPY")"
        sleep 2
        if sudo mount -o ro "${LOOPC}p1" "$BOOT_MNT" 2>/dev/null; then
            sudo test -e "$BOOT_MNT/$MARKER" && RESULT=ok-marker
            sudo umount "$BOOT_MNT" 2>/dev/null
        fi
        if [ "$RESULT" = timeout ] && sudo mount -o ro "${LOOPC}p2" "$ROOT_MNT" 2>/dev/null; then
            if sudo test -e "$ROOT_MNT/boot/firmware/$MARKER" || sudo test -e "$ROOT_MNT/boot/$MARKER"; then
                RESULT=ok-marker
            fi
            sudo umount "$ROOT_MNT" 2>/dev/null
        fi
        sudo losetup -d "$LOOPC" 2>/dev/null
        LOOPC=""
    fi

    echo "--- serial output captured: $(wc -c < "$LOG" 2>/dev/null || echo 0) bytes ---"
    tail -n 30 "$LOG" 2>/dev/null || true

    case "$RESULT" in
        ok-*) echo "RESULT $BOARD: PASS ($RESULT)" ;;
        panic) echo "RESULT $BOARD: FAIL (kernel panic / emergency mode)"; overall=1 ;;
        died) echo "RESULT $BOARD: FAIL (qemu exited during boot)"; overall=1 ;;
        *) echo "RESULT $BOARD: FAIL (no boot signal within ${TIMEOUT}s)"; overall=1 ;;
    esac

    sudo umount "$ROOT_MNT" 2>/dev/null
    sudo umount "$BOOT_MNT" 2>/dev/null
    if [ -n "$LOOPC" ]; then
        for _ in 1 2 3 4 5; do
            sudo losetup -d "$LOOPC" 2>/dev/null && break
            sleep 1
        done
    fi
    rm -f "$COPY"
done

echo ""
if [ "$overall" -eq 0 ]; then
    echo "PASS: image boots to multi-user on all tested boards ($BOARDS)"
    exit 0
fi
echo "FAIL: one or more boards did not boot"
exit 1
