AS         = nasm
ZIG        = zig build-exe

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

${BOOTLOADER}: always
	${AS} ${SRC_DIR}/bootloader/boot.s -f bin -o $@

${KERNEL}: always
	${AS} ${SRC_DIR}/kernel/main.s -f bin -o $@

tools: always
	@mkdir -p ${BUILD_DIR}/tools
	${ZIG} ${TOOLS_DIR}/fat/fat.zig -femit-bin=${BUILD_DIR}/tools/fat
	@rm -f ${BUILD_DIR}/tools/fat.o

always:
	@mkdir -p ${BUILD_DIR}

run: all
	qemu-system-i386 -fda ${IMG}

clean:
	rm -rf ${BUILD_DIR}

.PHONY: all always run clean
