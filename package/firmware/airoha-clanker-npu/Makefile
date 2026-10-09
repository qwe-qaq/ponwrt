include $(TOPDIR)/rules.mk

PKG_NAME:=airoha-clanker-npu
PKG_RELEASE:=79
PKG_CONFIG_DEPENDS:=CONFIG_MT7915_NPU_PROFILE CONFIG_MT7915_NPU_PROFILE_SHIFT
PKG_BUILD_DEPENDS:=airoha-riscv-toolchain/host
PKG_BUILD_PARALLEL:=1
CLANKER_PROF=$(if $(CONFIG_MT7915_NPU_PROFILE),1,0)
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/ClankerConstruction/ClankerNPU.git
PKG_SOURCE_VERSION:=735529c10d5120e10f7e4a6ddf97fb384fce9903
PKG_MIRROR_HASH:=e115d22e0e49fa8060f8d94ae78d65dcac0460e89ce5fa2d09500bf482408215
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-$(PKG_SOURCE_VERSION)
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_SOURCE_SUBDIR)

PKG_FILE_DEPENDS:=$(TOPDIR)/scripts/airoha-clanker-dhcp-repair.sh $(TOPDIR)/scripts/airoha-clanker-dhcp-diag.sh $(TOPDIR)/scripts/airoha-clanker-mode.uc $(TOPDIR)/scripts/airoha-clanker-lan-diag.sh $(TOPDIR)/scripts/airoha-clanker-offload.sh $(TOPDIR)/scripts/airoha-clanker-perf.uc $(TOPDIR)/scripts/airoha-clanker-diag.sh $(TOPDIR)/scripts/airoha-clanker-wifi-status.uc $(TOPDIR)/scripts/airoha-clanker-diag.init

PKG_LICENSE:=NOASSERTION
PKG_LICENSE_FILES:=README.md
PKG_MAINTAINER:=ponwrt contributors

include $(INCLUDE_DIR)/package.mk

define Package/airoha-en7581-clanker-mt7916-npu
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=ClankerNPU firmware for AN7581 and MT7916 Kite
  DEPENDS:=@TARGET_airoha_an7581 +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus
endef

define Package/airoha-en7581-clanker-mt7916-npu/description
  Open-source ClankerNPU AN7581/MT7916 firmware from commit
  $(PKG_SOURCE_VERSION). The upstream repository does not currently carry
  a separate SPDX license file; the source README is installed alongside
  the firmware. Redistribution follows the upstream permission confirmed
  for this integration.
endef

# Native host dependency installs a pinned bare-metal RISC-V compiler into
# staging_dir/hostpkg. An explicit override is available for diagnostics,
# but the ordinary build remains self-contained and reproducible.
CLANKER_RISCV_BIN ?= $(STAGING_DIR_HOSTPKG)/libexec/airoha-riscv/usr/bin
CLANKER_CROSS ?= $(CLANKER_RISCV_BIN)/riscv64-unknown-elf-
define Build/Compile
	+$(MAKE) -C $(PKG_BUILD_DIR) \
		CROSS="$(CLANKER_CROSS)" SOC=AN7581 WIFI=MT7916 \
		GITREV=$(PKG_SOURCE_VERSION) \
		CLANKER=0 MAILTRACE=0 NPUDBG=0 PROF=$(CLANKER_PROF) NPUTX=1
	test -s $(PKG_BUILD_DIR)/build/AN7581_MT7916/npu_rv32.bin
	test -s $(PKG_BUILD_DIR)/build/AN7581_MT7916/npu_data.bin
	test `wc -c < $(PKG_BUILD_DIR)/build/AN7581_MT7916/npu_rv32.bin` -le 2097152
	test `wc -c < $(PKG_BUILD_DIR)/build/AN7581_MT7916/npu_data.bin` -le 65536
	( printf '%s\n' \
		'Source: $(PKG_SOURCE_URL)' \
		'Commit: $(PKG_SOURCE_VERSION)' \
		'Variant: SOC=AN7581 WIFI=MT7916 CLANKER=0 MAILTRACE=0 NPUDBG=0 PROF=$(CLANKER_PROF) NPUTX=1' \
		'Local firmware changes: 100 RX validation; 101 diagnostics and transactional RX init; 102 extended control/BA and TDMA ownership; 103 ARM physical addresses and live control-only mode; 104 explicit host-ring lifetime and DMA quarantine; 105 DATA_STOP/DATA_RECOVER drain and retained-ring rearm; 106 host-ring consumption proof; 107 raw RX handoff for host reorder/PN; 108 security fallback metadata, mode-2 reorder candidate and generation fencing; 109 live-update reorder fence with raw-host downgrade; 110 completed security/fallback telemetry and reorder fences; 111 full-width host metadata; 112 AN7581 PCIe windows and RX ring observation; 113 unsupported-control metadata stub; 114 stopped-host sentinel consumption, producer-index rearm and SEC_MODE-only encrypted counters; 115 MT7916 dual-band NPU TX descriptor transport, negotiated hart4 fencing and validated DDR/MMIO publication; 116 complete PPE ingress/return, shared PN/BA security, native MT7916 downlink and lifetime fences; 117 whole-MPDU injection guard and identity-valid protocol-fault stop; 118 cfg80211 QoS map and validated single-TID BAR window; 120 native MT7916 token/PID contract; 119 preserve firmware fault identity on host WA errors; 121 RX policy-hit/miss and TDMA-full evidence; 122 restore DMA alignment with reserved statistics and ABI4 layout assertions; 123 publish accepted PN proof before encrypted RX policy lookup; 124 bridge L2 capture, NPU L4 policy hit/miss and host-adaptor software TX fallback; 126 fallback session/generation/key-generation fence; 127 allow open-network key_generation=0; 128 explicit bridge capture authorization and normalized bridge L4 hash; 129 self-contained Kite firmware type interfaces; 130 transactional bridge capture lookup version fence; 131 hart3-only bridge fallback copy, canonical single-frame descriptor, fault10 proven-stop contract; 132 RX early-admission and TX gate-drop diagnostics (reserved statistics, unchanged ABI4); 133 ABI5 tail quality counters and retired bridge capture guard; 137 H3C-derived ABI8 TDMA/rearm/publish/DMA/ready/fallback stage counters' \
		'Release52 scope: remove optional proxy/tunnel packages from image; reduce healthy summaries only (DP/TX 60s, NPU 120s); unchanged NPU binary logic, ABI5, DMA memory layout and r51 datapath' \
		'Release51 quality: fully revalidated identical flow refresh reuse; shared capture refs and retired deny guards; native L2 representative promotion; quality_band and dp_pause evidence; uplink acceleration deferred' \
		'Kite GET31 legacy ownership ABI: 1; legacy capabilities: 0 (not DATAPATH state); lifecycle capability: 128 (development data mode); security fallback/meta/reorder capabilities: 256/1024/512' \
		'Kite read-only diagnostics: GET32 ABI 1; 16 pages; 248-byte payload; page1 words43..58 completed-frame security/fallback counters, 59..60 reorder active/fences, 61 telemetry magic; page2 PCIe windows and WFDMA RX rings; page3 KH2 host BUSY/reject/HOLD; page4 KP1 full PS exact-policy miss; page5/6 KC1 band costs; page7 KF1 band credit and sampled STA pressure; page8 FE1 actual feed batches; page9 KI1 profiler/memory, page10/11 CPI, page12 disabled, page13..15 PC histogram' \
		'Kite control: SET33/GET33 ABI 2; TX capability 2048, DATAPATH capability 4096; commands 14/15 TX bind/unbind, 16/17 DP bind/unbind, 18 RX purge; worker mask 0x1e' \
		'Kite datapath: shared ABI 12 (tail-only PS/pressure/idle observations; DMA offsets preserved), TX ownership ABI 2; host/NPU shared RX PN authority; exact Linux flow admission; hardware FOE learning; TDMA PPE downlink, native TXD/TXP, WTBL TX PN/SN, DMA+WA completion' \
		'Release78: 158/189/997/608; ABI12 unchanged; disabled-observer bypass, warm STA read-only hits, linear skb accounting, PS empty hints with full proof, FQ burst and wired boundary evidence; batch16 hart4 WED/cache' \
		'Release79: 159/190/998/609; ABI12 unchanged; PROF=1 PC/CPI/memory-latency diagnostics, profile0 hart4 busy/idle counters, demand-only dual-band credit, bounded fault mirror and WAN read reduction, four-entry LAN recent-hint front end, Kite-only safe skb copy on oversized forwarded WiFi frames, event-first PS wake with 100ms lost-event watchdog; single hart4 batch16 WED/cache' \
		'Release75: 155/186/994; ABI12 unchanged; bounded route proof and counter publication, demand-based cross-band credit, DMA+WA per-STA accounting, empty PS mutation skip, KF1 queue and per-band host WA evidence; schema8 explicit stop and markers; profile0 normal / profile10 diagnostic, WED/cache batch16 single hart4' \
		'Release74: 154/185/993; ABI12 unchanged; uncached KC1 revision74 and KP1, producer freshness; unsampled call elision; bounded STA context, bridge-first exact lookup, PS fast rejection with full final proof; profile0 normal / profile10 cold diagnostic, WED/cache batch16 single hart4' \
		'Release73: 153/185/992; ABI12 unchanged; KC1 sampled inner costs, host tail and MPDU source evidence; locked GSW/PHY snapshot; upstream lifecycle fixes; schema7 profile10 WED/cache batch16 single hart4' \
		'Release72: 152/184/989; ABI12 unchanged; bounded pre-DMA host BUSY retry; bridge FDB/VLAN GC revalidation; KH2 host congestion and KP1 exact-policy miss; schema6 complete wired-window evidence; profile0 WED/cache batch16 single hart4' \
		'Release71: 151/184/987 + mac80211 606; ABI12 datapath unchanged from r70; flow/conntrack/refresh RCU lifetime repair; CPU-port PAUSE and read-only QDMA state; host rejection vs HOLD causes; recorder schema5; native profile0/profile6 cold-image comparison; lan1 remains WAN' \
		'Release70: 150/184/985 + mac80211 606; ABI12 single hart4 batch16; compact TX-only private STA prefix, bounded session/epoch context and freed publication, profile-off skips token age stores; separate MPDU final failures; recorder schema4 physical pause/drop and endpoint evidence; wed/cache default on' \
		'Release69: 149/183/985 + mac80211 606; ABI12 single hart4 batch16; default npu_cached_hdr=Y (self-tested fallback) and existing wed_enable=Y; corrected host L3 metadata/native QoS, BA completion schedules full PS proof, BIND-seeded fixed TXWI words with eight mutable writes, batched exact-hit statistics' \
		'Release68: 148/182/985 + mac80211 606; ABI12 layout unchanged; opt-in npu_cached_hdr (default off) reads the TX header line through the hart4 D-cache after a 0xFC2 line invalidate, with on-core self-test reported as r68_cache' \
		'Release67: 147/181/984 + mac80211 606; ABI12 unchanged; native-only TX BA for non-KDP peers when NPU ownership is provably absent; PS drain proof scans the band ring for the target WCID instead of refusing on any ready head; r67_fix counters' \
		'Release66: 146/180/984 + mac80211 606; ABI12 batch16 single hart4; complete DMA76 TXWI, boot flags context, bounded pressure proof and word snapshots; two-stage PS queue drain with native scheduling, activity-aware ingress scans and real lightweight observation' \
		'Release65: 145/179/983; ABI12 batch16 single hart4; exact last-policy probe; candidate-only learning; NAPI-batched PS progress; batched FE readout, bounded PPE/static cache, single-read lightweight collector' \
		'Release64: 144/178/982; ABI12 unchanged; same-cookie L2 index refresh, exact suspended-rule retention, restartable learning, SRAM transition observation and batched counters, stage-coalesced PS progress, native authorized host fallback; batch16 single hart4' \
		'Release63: 143/177/981; ABI12; native flow reauthorization after PS, progress-driven bounded drain, gate hold, private-key-first lookup and idle-token backpressure, batched WFDMA ownership fence, bounded cause/PS observations; full128 TXWI, batch16, single hart4' \
		'Release62: 142; single-pass owned IPv4 word parser, compact held-token retry without payload reread, cold STA-fill/host-reap separation; exact live policies, full128-byte TXWI and DMA+WA ownership unchanged; host driver remains r61, ABI11, batch16, single hart4' \
		'Release61: 176 + mac80211 605; bounded software backlog probe without RCU wait or AQL-zero requirement; fixed native WFDMA prefix on PS wake, exact handoff/identity checks and r61_ps reason/timing telemetry; NPU patches 100-141 unchanged, ABI11, batch16, single hart4' \
		'Release60: 141/175/980 + mac80211 604; wire-order keys, separate generic path, exact PS suspend records, ordered host handoff and queue drain, TDMA bind readback and actual-traffic ingress fallback; default batch16, single hart4' \
		'Review repair: 117/139/945; PN rejection enforced at delivery; exact nft bridge L4 policy uses software fallback; routed PPE candidate requires hardware validation' \
		'Release55: 136/170/976 + mac80211 603; ABI8; private word-prefix/exact-policy/STA cache, complete word TXWI, 8-packet TDMA/WFDMA publication, event completion with bounded rescue, native BA TX activity, whole-loop and split wire latency; unchanged payload offsets and security contracts' \
		'Release59: 140/174/979 ABI10; single-hart compact IPv4 exact-key and validated STA context; bounded 8-slot per-band HOST-owned fallback FIFO and PS wake/revoke coalescing; 32-token WA completion batches, stage/age/PS/WA/NAPI/aggregation observations; old DMA offsets and double-completion retained' \
		'Release58: 139/173/978 ABI9; single-hart snapshot completion, pending bitmap rescue, version-proven WAN domain cache, 8/16 publish selector, acknowledged per-STA/TID BA drain and stage/pressure telemetry; old DMA offsets preserved' \
		'Release57: 138/172; private hart4 performance counters, word-prefix IPv4 parser, pure L2 hash cache with live policy scans, submit/other loop observation; ABI8 and all ownership/security/recovery contracts unchanged' \
		'Release56: 137/171; ABI8 unchanged; H3C-derived stage counters and host WA producer publication suppression when no new events; no descriptor, token, PN, recovery or reserved-memory contract changes' \
		'Release54: 135/169/975 ABI7; QoS-map-compatible IPv4 parser; eight bounded positive hints per band; sampled hart4 cycles and DMA/WA ages; gate durations and PPE errno classes; native survey/queue aggregation evidence; npu_profile=6 by default, 0 disables sampling' \
		'Performance candidate r53: 134/168/974; boot-only npu_perf and npu_amsdu controls; exact IPv4 hints and held-parse reuse; single-writer free/completion queues; native MCU-acknowledged A-MSDU length and per-TID BA contract; no broad L2 authorization' \
		'Kite datapath limits: AN7581 MT7916 AP, open/CCMP unicast; unsupported security/4addr/PS/TWT/ACM use host paths; configured DSCP maps are supported; rx_free_only and tx_freed are ownership completion, not endpoint delivery proof' \
		'Host integration candidate: firmware package release77; kernel patches 952-996; mt76 patches 120-189/release61; mac80211 release10/607; exact pre-route Ethernet matches use the reverse route gateway and peer, independently resolving DIRECT/NEIGH and post-NAT neighbors; native Ethernet MANGLE actions supply PPE output MACs; cookie replacements fully revalidate; identical live policies reuse; changed or invalid policies revoke, failed fences retain ownership; LAN bridge L2 capture publishes a separate capture authorization, NPU bridge policy carries IPv4/IPv6 TCP/UDP and ports, policy misses and non-L4/control frames use host fallback; bridge L4 and routed L4 hashes normalize wire IPv4/IPv6 types; fallback descriptors are fenced by session, band, station generation, key generation, DP authorization and VIF binding; 165 selects the station band PHY for host fallback and reports rejection reasons; WAN-routed PPE fast path remains unchanged; exact MAC-only bridge L2B egress is admitted by kernel patches 965-966; mt7915 recovery proof, idempotent reset, radio retry, persistent proven-stop retry with exponential backoff, timeout status resolution, transition snapshots, bounded event history and low-rate NPU/PPE/TX telemetry are patches 147-152/158-163; PPE learning scans are coalesced and serialized by kernel patches 963-964'; \
		printf '%s\n' 'Patch set: 100-159 (applied by ImmortalWrt package prepare); mt76 patches 120-190 via native package prepare; Linux/Airoha through 998, including 986 RCU lifetime, 987 host/CPU-port evidence, 988 bridge path GC, 989 KH2/KP1 diagnostics; shared ABI12 unchanged'; \
		find $(CURDIR)/patches -maxdepth 1 -type f -printf '%f\n' | sort; \
		$(CLANKER_CROSS)gcc --version | head -n 1; \
		cd $(PKG_BUILD_DIR)/build/AN7581_MT7916 && sha256sum npu_rv32.bin npu_data.bin \
	) > $(PKG_BUILD_DIR)/ponwrt-buildinfo.txt
endef

define Package/airoha-en7581-clanker-mt7916-npu/install
	$(INSTALL_DIR) $(1)/lib/firmware/airoha $(1)/usr/sbin $(1)/usr/share $(1)/etc/init.d
	$(INSTALL_BIN) $(TOPDIR)/scripts/airoha-clanker-dhcp-repair.sh $(1)/usr/sbin/airoha-clanker-dhcp-repair
	$(INSTALL_BIN) $(TOPDIR)/scripts/airoha-clanker-dhcp-diag.sh $(1)/usr/sbin/airoha-clanker-dhcp-diag
	$(INSTALL_BIN) $(TOPDIR)/scripts/airoha-clanker-lan-diag.sh $(1)/usr/sbin/airoha-clanker-lan-diag
	$(INSTALL_BIN) $(TOPDIR)/scripts/airoha-clanker-offload.sh $(1)/usr/sbin/airoha-clanker-offload
	$(INSTALL_BIN) $(TOPDIR)/scripts/airoha-clanker-diag.sh $(1)/usr/sbin/airoha-clanker-diag
	$(INSTALL_DATA) $(TOPDIR)/scripts/airoha-clanker-mode.uc $(1)/usr/share/airoha-clanker-mode.uc
	$(INSTALL_DATA) $(TOPDIR)/scripts/airoha-clanker-perf.uc $(1)/usr/share/airoha-clanker-perf.uc
	$(INSTALL_DATA) $(TOPDIR)/scripts/airoha-clanker-wifi-status.uc $(1)/usr/share/airoha-clanker-wifi-status.uc
	$(INSTALL_BIN) $(TOPDIR)/scripts/airoha-clanker-diag.init $(1)/etc/init.d/airoha-clanker-diag
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/build/AN7581_MT7916/npu_rv32.bin \
		$(1)/lib/firmware/airoha/en7581_MT7916_npu_rv32.bin
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/build/AN7581_MT7916/npu_data.bin \
		$(1)/lib/firmware/airoha/en7581_MT7916_npu_data.bin
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/README.md \
		$(1)/lib/firmware/airoha/en7581_MT7916_ClankerNPU_SOURCE.md
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/ponwrt-buildinfo.txt \
		$(1)/lib/firmware/airoha/en7581_MT7916_ClankerNPU_BUILDINFO.txt
endef

$(eval $(call BuildPackage,airoha-en7581-clanker-mt7916-npu))
