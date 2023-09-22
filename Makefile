ARCH       = x86_64
IMAGE_NAME = système-9-${ARCH}
# ZIGFLAGS   = -Doptimize=ReleaseFast

all: ${IMAGE_NAME}.iso

all-hdd: ${IMAGE_NAME}.hdd

run: ${IMAGE_NAME}.iso
	qemu-system-x86_64 -M q35 -m 2G -cdrom ${IMAGE_NAME}.iso -boot d

run-uefi: ovmf ${IMAGE_NAME}.iso
	qemu-system-x86_64 -M q35 -m 2G -bios ovmf/OVMF.fd -cdrom ${IMAGE_NAME}.iso -boot d

run-hdd: ${IMAGE_NAME}.hdd
	qemu-system-x86_64 -M q35 -m 2G -hda ${IMAGE_NAME}.hdd

run-hdd-uefi: ovmf ${IMAGE_NAME}.hdd
	qemu-system-x86_64 -M q35 -m 2G -bios ovmf/OVMF.fd -hda ${IMAGE_NAME}.hdd

ovmf:
	mkdir -p ovmf
	cd ovmf && curl -Lo OVMF.fd https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd

limine:
	git clone https://github.com/limine-bootloader/limine.git --branch=v5.x-branch-binary --depth=1
	${MAKE} -C limine

kernel:
	zig build ${ZIGFLAGS}

${IMAGE_NAME}.iso: limine kernel
	rm -rf iso_root
	mkdir -p iso_root
	cp -v zig-out/bin/kernel.elf\
		limine.cfg limine/limine-bios.sys limine/limine-bios-cd.bin limine/limine-uefi-cd.bin iso_root/
	mkdir -p iso_root/EFI/BOOT
	cp -v limine/BOOTX64.EFI iso_root/EFI/BOOT/
	cp -v limine/BOOTIA32.EFI iso_root/EFI/BOOT/
	xorriso -as mkisofs -b limine-bios-cd.bin \
		-no-emul-boot -boot-load-size 4 -boot-info-table \
		--efi-boot limine-uefi-cd.bin \
		-efi-boot-part --efi-boot-image --protective-msdos-label \
		iso_root -o ${IMAGE_NAME}.iso
	./limine/limine bios-install ${IMAGE_NAME}.iso
	rm -rf iso_root

${IMAGE_NAME}.hdd: limine kernel
	rm -f ${IMAGE_NAME}.hdd
	dd if=/dev/zero bs=1M count=0 seek=64 of=${IMAGE_NAME}.hdd
	sgdisk ${IMAGE_NAME}.hdd -n 1:2048 -t 1:ef00
	./limine/limine bios-install ${IMAGE_NAME}.hdd
	mformat -i ${IMAGE_NAME}.hdd@@1M
	mmd -i ${IMAGE_NAME}.hdd@@1M ::/EFI ::/EFI/BOOT
	mcopy -i ${IMAGE_NAME}.hdd@@1M zig-out/bin/kernel.elf limine.cfg limine/limine-bios.sys ::/
	mcopy -i ${IMAGE_NAME}.hdd@@1M limine/BOOTX64.EFI ::/EFI/BOOT
	mcopy -i ${IMAGE_NAME}.hdd@@1M limine/BOOTIA32.EFI ::/EFI/BOOT

clean:
	rm -rf zig-cache zig-out iso_root
	rm -f ${IMAGE_NAME}.iso ${IMAGE_NAME}.hdd

distclean: clean
	rm -rf ovmf limine

.PHONY: all all-hdd run run-uefi run-hdd run-hdd-uefi kernel clean distclean
