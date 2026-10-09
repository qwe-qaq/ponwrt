# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=airoha-riscv-toolchain
PKG_VERSION:=14.2.0+19
PKG_RELEASE:=1
PKG_HOST_ONLY:=1

# The r65 reference compiler is Ubuntu's bare-metal multilib compiler.
# riscv64 in its name does not imply RV64 output: Clanker selects RV32/ILP32.
PKG_SOURCE:=gcc-riscv64-unknown-elf_$(PKG_VERSION)_amd64.deb
PKG_SOURCE_URL:=https://archive.ubuntu.com/ubuntu/pool/universe/g/gcc-riscv64-unknown-elf
PKG_HASH:=6f68c9033163173f1872be0a9aed0e0d508bf83910fcccb20a665c3ba2635555

RISCV_BINUTILS_VERSION:=2.45.50.20251209-1ubuntu1+7build1
RISCV_BINUTILS_SOURCE:=binutils-riscv64-unknown-elf_$(RISCV_BINUTILS_VERSION)_amd64.deb
RISCV_TOOLCHAIN_DIR:=$(STAGING_DIR_HOSTPKG)/libexec/airoha-riscv
RISCV_ARCH:=-march=rv32imc_zicsr_zifencei -mabi=ilp32

PKG_LICENSE:=GPL-3.0-or-later GCC-exception-3.1
PKG_LICENSE_FILES:=usr/share/doc/gcc-riscv64-unknown-elf/copyright usr/share/doc/binutils-riscv64-unknown-elf/copyright

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/host-build.mk

define Download/riscv-binutils
  FILE:=$(RISCV_BINUTILS_SOURCE)
  URL:=https://archive.ubuntu.com/ubuntu/pool/universe/b/binutils-riscv64-unknown-elf
  HASH:=bfab55db7724fa71941ac90981f444dee5aaa0942ef8332650a5009e6d61e999
endef
$(eval $(call Download,riscv-binutils))

define Package/airoha-riscv-toolchain
  SECTION:=devel
  CATEGORY:=Development
  TITLE:=Pinned r65 bare-metal RISC-V host toolchain
  BUILDONLY:=1
endef

define Host/Prepare
	@test "$(shell uname -s)/$(shell uname -m)" = Linux/x86_64 || { \
		echo 'The r65 reference toolchain requires a Linux x86_64 glibc host.' >&2; exit 1; }
	mkdir -p $(HOST_BUILD_DIR)
	ar p $(DL_DIR)/$(PKG_SOURCE) data.tar.zst | $(STAGING_DIR_HOST)/bin/zstd -dc | tar -xf - -C $(HOST_BUILD_DIR)
	ar p $(DL_DIR)/$(RISCV_BINUTILS_SOURCE) data.tar.zst | $(STAGING_DIR_HOST)/bin/zstd -dc | tar -xf - -C $(HOST_BUILD_DIR)
endef

define Host/Configure
endef

# Link a real RV32 division helper to check the relocated ILP32 libgcc too.
define Host/Compile
	$(HOST_BUILD_DIR)/usr/bin/riscv64-unknown-elf-gcc --version
	printf '%s\n' 'unsigned long long probe(unsigned long long a, unsigned long long b) { return a / b; }' > $(HOST_BUILD_DIR)/probe.c
	$(HOST_BUILD_DIR)/usr/bin/riscv64-unknown-elf-gcc $(RISCV_ARCH) \
		-ffreestanding -nostdlib -Wl,-e,probe $(HOST_BUILD_DIR)/probe.c -lgcc -o $(HOST_BUILD_DIR)/probe.elf
	$(HOST_BUILD_DIR)/usr/bin/riscv64-unknown-elf-readelf -h $(HOST_BUILD_DIR)/probe.elf
endef

define Host/Install
	$(INSTALL_DIR) $(RISCV_TOOLCHAIN_DIR)
	$(CP) $(HOST_BUILD_DIR)/usr $(RISCV_TOOLCHAIN_DIR)/
	$(RISCV_TOOLCHAIN_DIR)/usr/bin/riscv64-unknown-elf-gcc $(RISCV_ARCH) \
		-ffreestanding -nostdlib -Wl,-e,probe $(HOST_BUILD_DIR)/probe.c -lgcc -o $(HOST_BUILD_DIR)/probe-installed.elf
endef

define Host/Clean
	rm -rf $(RISCV_TOOLCHAIN_DIR)
endef

$(eval $(call BuildPackage,airoha-riscv-toolchain))
$(eval $(call HostBuild))
