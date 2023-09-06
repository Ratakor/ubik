AS         = nasm
SRC_DIR    = src
BUILD_DIR  = build

IMG        = ${BUILD_DIR}/floppy.img
BOOTLOADER = ${BUILD_DIR}/bootloader.bin
KERNEL     = ${BUILD_DIR}/kernel.bin

all: ${IMG}

${IMG}: ${BOOTLOADER} ${KERNEL}
	dd if=/dev/zero of=${IMG} bs=512 count=2880
	mkfs.fat -F 12 -n "NBOS" ${IMG}
	dd if=${BUILD_DIR}/bootloader.bin of=${IMG} conv=notrunc
	mcopy -i ${IMG} ${BUILD_DIR}/kernel.bin "::kernel.bin"

${BOOTLOADER}: always
	${AS} ${SRC_DIR}/bootloader/boot.s -f bin -o $@

${KERNEL}: always
	${AS} ${SRC_DIR}/kernel/main.s -f bin -o $@

always:
	mkdir -p ${BUILD_DIR}

run: all
	qemu-system-i386 -fda ${IMG}

clean:
	rm -rf ${BUILD_DIR}

.PHONY: all always run clean
