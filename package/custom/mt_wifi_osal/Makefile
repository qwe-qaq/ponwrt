include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=mt_wifi_osal
PKG_RELEASE:=1
PKG_BUILD_DIR:=$(KERNEL_BUILD_DIR)/$(PKG_NAME)/wifi_osal
PKG_SOURCE:=mt_wifi_osal-543726.tar.xz
PKG_SOURCE_URL:=https://github.com/chasey-dev/objs/releases/download/v1
PKG_HASH:=102bf755e7d5b8a92767068ff03abe44ede05a2158936e76a793244acdb6d25a

PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define KernelPackage/$(PKG_NAME)
  CATEGORY:=MTK Properties
  SUBMENU:=Drivers
  TITLE:=MediaTek WiFi OS Abstraction Layer
  DEPENDS:=+MTK_WIFI_OSAL_CFG80211_SUPPORT:kmod-cfg80211
  FILES:=$(PKG_BUILD_DIR)/mt_wifi_osal.ko
  AUTOLOAD:=$(call AutoLoad,60,$(if $(CONFIG_MTK_WIFI_OSAL_CFG80211_SUPPORT), cfg80211) mt_wifi_osal,1)
endef

BACKPORT_VERSION:=$(lastword $(subst /, , $(shell find $(KERNEL_BUILD_DIR) -type 'd' -name 'backports*')))
EXTRA_KCONFIG += CFG_CFG80211_VERSION:=$(word 2,$(subst -, ,$(BACKPORT_VERSION)))

# vendor 的 Kbuild 用相对路径 -Iinclude/uapi/linux/mtk_nl80211_inc 找 mtk_vendor_nl80211.h，
# 该文件由 target/linux/*/files-<ver>/ 在 Kernel/Prepare 时拷进内核树。CI 的 build_dir
# 缓存若来自更早的提交，Kernel/Prepare 不会重跑，内核树里就没有这个头 —— 此时退回仓库内
# 的原始目录（内容同源，只是不依赖内核树是否被刷新过）。
MTK_NL80211_INC_DIR := $(if $(wildcard $(LINUX_DIR)/include/uapi/linux/mtk_nl80211_inc/mtk_vendor_nl80211.h),,\
	$(firstword $(wildcard $(TOPDIR)/target/linux/*/files-*/include/uapi/linux/mtk_nl80211_inc)))

# Linux 6.18 的 kbuild 已移除 EXTRA_CFLAGS（传了也会被静默丢弃），必须改用
# CFLAGS_MODULE 下发：它在 scripts/Makefile.lib 的 c_flags 中排在 ccflags-y 之后，
# 可压过 vendor Kbuild 自带的 -Werror。6.18 默认打开 -Wextra、-Wmissing-prototypes、
# -Wmissing-declarations，原厂代码在这三类上不可能清零，故整体降级为 warning。
PKG_EXTRA_CFLAGS:= -Wno-error -Wno-missing-prototypes -Wno-missing-declarations \
		$(if $(MTK_NL80211_INC_DIR),-I$(MTK_NL80211_INC_DIR)) \
		$(if $(CONFIG_MTK_WIFI_OSAL_CFG80211_SUPPORT), -DCFG80211_SUPPORT) \
		$(if $(CONFIG_MTK_WIFI_OSAL_DEBUG), -DMT_DEBUG) \
		$(if $(CONFIG_MTK_WIFI_OSAL_CUSTOM_VPRINTK), -DCUSTOM_FACILITY=$(CONFIG_MTK_WIFI_OSAL_CUSTOM_VPRINTK_FACILITY)) \
		$(if $(CONFIG_MTK_WIFI7_VLAN_GTK_SUPPORT), -DCONFIG_VLAN_GTK_SUPPORT) \
		$(if $(CONFIG_MTK_WIFI_OSAL_NETIF_RX_DISPATCH), -DCONFIG_NETIF_RX_DISPATCH)

NOSTDINC_FLAGS :=
ifeq ($(CONFIG_MTK_WIFI_OSAL_CFG80211_SUPPORT),y)
NOSTDINC_FLAGS += \
        $(KERNEL_NOSTDINC_FLAGS) \
        -DBACKPORT_NOSTDINC \
        -I$(PKG_BUILD_DIR) \
        -I$(PKG_BUILD_DIR)/include \
        -I$(STAGING_DIR)/usr/include/mac80211-backport \
        -I$(STAGING_DIR)/usr/include/mac80211-backport/uapi \
        -I$(STAGING_DIR)/usr/include/mac80211 \
        -I$(STAGING_DIR)/usr/include/mac80211/uapi \
        -include backport/backport.h
endif

define KernelPackage/$(PKG_NAME)/config
	source "$(SOURCE)/Config.in"
endef

define Build/Compile
	+$(KERNEL_MAKE) $(PKG_JOBS) \
		M="$(PKG_BUILD_DIR)" \
		NOSTDINC_FLAGS="$(NOSTDINC_FLAGS)" \
		CFLAGS_MODULE="$(PKG_EXTRA_CFLAGS)" \
		$(EXTRA_KCONFIG) \
		KBUILD_EXTRA_SYMBOLS="$(wildcard $(PKG_SYMVERS_DIR)/*.symvers)" \
		modules
endef

define Build/InstallDev
	mkdir -p $(1)/usr/include/mt_wifi/os
	$(CP) $(PKG_BUILD_DIR)/inc/* $(1)/usr/include/mt_wifi/os
endef

define KernelPackage/$(PKG_NAME)/description
  MediaTek WiFi OS Abstraction Layer
endef


$(eval $(call KernelPackage,mt_wifi_osal))
