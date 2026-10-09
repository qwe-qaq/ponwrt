# r65 RISC-V 编译器来源

此包仅安装构建主机工具，不进入路由器 rootfs。它由
`airoha-clanker-npu` 的原生 `PKG_BUILD_DEPENDS` 拉入，使用 ImmortalWrt
Download/HostBuild、`dl/`、`build_dir/hostpkg/` 和 `staging_dir/hostpkg/`。
无需 root、系统安装或 `/tmp/riscv-toolchain-*`。

固定的 Ubuntu 官方 amd64 安装包：

| 输入 | 版本 | SHA256 |
| --- | --- | --- |
| gcc-riscv64-unknown-elf | 14.2.0+19 | `6f68c9033163173f1872be0a9aed0e0d508bf83910fcccb20a665c3ba2635555` |
| binutils-riscv64-unknown-elf | 2.45.50.20251209-1ubuntu1+7build1 | `bfab55db7724fa71941ac90981f444dee5aaa0942ef8332650a5009e6d61e999` |

下载地址在 Makefile；两者来自 `https://archive.ubuntu.com/ubuntu/pool/universe/`。
本次从上述安装包独立解压的865个普通文件，与原r65临时目录逐文件SHA256一致。
原包的 copyright 和文档一起安装；GCC源包为Ubuntu
`gcc-riscv64-unknown-elf (19)`，binutils源包为
`binutils-riscv64-unknown-elf (7build1)`，Built-Using binutils
`2.45.50.20251209-1ubuntu1`。

参考主机要求 Linux x86_64、glibc >= 2.38，以及 libgcc-s1、libgmp10
（>= 6.3）、libisl23、libmpc3、libmpfr6、libstdc++6、libzstd1、zlib1g。
本次主机是 Ubuntu 26.04.1。不能在 ARM/macOS 主机上直接运行这些 amd64 工具。

编译器名中的 riscv64 是工具链前缀，实际Clanker参数为
`-march=rv32imc_zicsr_zifencei -mabi=ilp32`。链接器使用
`-m elf32lriscv -T link.ld -nostdlib --gc-sections --relax`，libgcc路径通过
相同ARCH参数的 `gcc -print-libgcc-file-name` 获取，不能误用RV64 libgcc。
Host/Compile 和 Host/Install 都实际链接RV32除法程序，检查解压与迁移后的multilib。

NPU包保持原r65 `SOC=AN7581 WIFI=MT7916 CLANKER=0 MAILTRACE=0 NPUDBG=0
PROF=0 NPUTX=1` 和固定GITREV。只由原生prepare应用100–145补丁，再从源码编译
`npu_rv32.bin` 和 `npu_data.bin`。Makefile中的二进制长度上限检查仍保留。

普通构建不需要source任何脚本。需要手工查看编译器时，在仓库根执行：

```sh
make -j$(nproc) package/devel/airoha-riscv-toolchain/host/compile V=s
. ./scripts/airoha-riscv-env.sh
"${CLANKER_CROSS}gcc" -march=rv32imc_zicsr_zifencei -mabi=ilp32 -print-libgcc-file-name
```

显式设置 `CLANKER_CROSS`/`CLANKER_RISCV_BIN` 是实验覆盖，不能直接沿用r65
二进制一致性结论。原生依赖依旧准备上述固定工具链。
