AS         = nasm

SRC_DIR    = src
TOOLS_DIR  = tools
BUILD_DIR  = build

IMG        = ${BUILD_DIR}/floppy.img
BOOTLOADER = ${BUILD_DIR}/bootloader.bin
KERNEL     = ${BUILD_DIR}/kernel.bin

all: ${IMG} tools

${IMG}: ${BOOTLOADER} ${KERNEL}
	dd if=/dev/zero of=${IMG} bs=512 count=2880
	mkfs.fat -F 12 -n "NBOS" ${IMG}
	dd if=${BUILD_DIR}/bootloader.bin of=${IMG} conv=notrunc
	mcopy -i ${IMG} ${BUILD_DIR}/kernel.bin "::kernel.bin"
	mcopy -i ${IMG} test.txt "::test.txt"

${BOOTLOADER}: ${BUILD_DIR}
	${AS} ${SRC_DIR}/bootloader/boot.s -f bin -o $@

${KERNEL}: ${BUILD_DIR}
	${AS} ${SRC_DIR}/kernel/main.s -f bin -o $@

tools:
	cd ${TOOLS_DIR}/fat && zig build
	@mkdir -p ${BUILD_DIR}/tools
	cp -f ${TOOLS_DIR}/fat/zig-out/bin/fat ${BUILD_DIR}/tools/fat

${BUILD_DIR}:
	@mkdir -p ${BUILD_DIR}

run: all
	qemu-system-i386 -fda ${IMG}

clean:
	rm -rf ${BUILD_DIR}

.PHONY: all tools run clean
