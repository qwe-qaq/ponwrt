#!/bin/sh
# Optional interactive access to the native r65 host toolchain.
# Source from the checkout root after native make has prepared it.
# Normal firmware builds install/select it automatically; no sourcing needed.

_clanker_bin=${CLANKER_RISCV_BIN:-$PWD/staging_dir/hostpkg/libexec/airoha-riscv/usr/bin}
if [ ! -x "$_clanker_bin/riscv64-unknown-elf-gcc" ]; then
	echo 'Run make package/devel/airoha-riscv-toolchain/host/compile first.' >&2
	unset _clanker_bin
	return 1 2>/dev/null || exit 1
fi
export CLANKER_RISCV_BIN="$_clanker_bin"
export CLANKER_CROSS="$_clanker_bin/riscv64-unknown-elf-"
case ":$PATH:" in
	*":$_clanker_bin:"*) ;;
	*) PATH="$_clanker_bin:$PATH"; export PATH ;;
esac
unset _clanker_bin
