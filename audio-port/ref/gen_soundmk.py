# -*- coding: utf-8 -*-
# 在 sound.mk 的 sound-soc-ac97 包后插入 kmod-sound-soc-ath79
import io

c = io.open('sound.mk', encoding='utf-8', newline='').read()
anchor = '$(eval $(call KernelPackage,sound-soc-ac97))'
assert anchor in c, 'anchor not found'

block = anchor + '''

define KernelPackage/sound-soc-ath79
  TITLE:=AR9331 SoC sound support (I2S + MBOX DMA)
  DEPENDS:=@TARGET_ath79 +kmod-sound-soc-core
  KCONFIG:=\\
	CONFIG_SND_SOC_ATH79 \\
	CONFIG_SND_SIMPLE_CARD \\
	CONFIG_SND_SIMPLE_CARD_UTILS \\
	CONFIG_SND_SOC_WM8988
  FILES:=\\
	$(LINUX_DIR)/sound/soc/ath79/snd-soc-ath79.ko \\
	$(LINUX_DIR)/sound/soc/codecs/snd-soc-wm8988.ko \\
	$(LINUX_DIR)/sound/soc/generic/snd-soc-simple-card.ko \\
	$(LINUX_DIR)/sound/soc/generic/snd-soc-simple-card-utils.ko
  AUTOLOAD:=$(call AutoLoad,56,snd-soc-ath79 snd-soc-wm8988 snd-soc-simple-card-utils snd-soc-simple-card)
  $(call AddDepends/sound)
endef

$(eval $(call KernelPackage,sound-soc-ath79))'''

c = c.replace(anchor, block, 1)
io.open('sound.mk.new', 'w', encoding='utf-8', newline='\n').write(c)
print('written, lines:', len(c.splitlines()))
