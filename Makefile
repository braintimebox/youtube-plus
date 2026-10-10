# YouTube Plus — Makefile
#
# Два режима сборки из одного Makefile:
#   1) .deb (для джейлбрейка) :  make package JAILBROKEN=1
#   2) .ipa (для сайдлоада)   :  make package FINALPACKAGE=1
#      (требует установленного модуля theos-jailed и распакованной базы в tmp/)

export ARCHS = arm64
export TARGET = iphone:clang:16.5:14.0
export SDK_PATH = $(THEOS)/sdks/iPhoneOS16.5.sdk/
export SYSROOT = $(SDK_PATH)

# Модуль jailed даёт упаковку .ipa. Для .deb его не подключаем.
ifneq ($(JAILBROKEN),1)
MODULES = jailed
endif

PACKAGE_NAME    = YouTubePlus
PACKAGE_VERSION = 1.0.0

INSTALL_TARGET_PROCESSES = YouTube

TWEAK_NAME = YouTubePlus
YouTubePlus_FILES    = Tweak.x
YouTubePlus_FRAMEWORKS = UIKit Security LinkPresentation
YouTubePlus_CFLAGS   = -fobjc-arc
# theos-jailed берёт базовое приложение отсюда (каталог .app, см. module/bin/stage.sh)
YouTubePlus_IPA     = $(THEOS_PROJECT_DIR)/tmp/Payload/YouTube.app

# Внешний вид и идентификатор приложения после инъекции.
# BUNDLE_ID задаётся из CI (workflow_dispatch); по умолчанию — исходный YouTube.
DISPLAY_NAME ?= YouTube
BUNDLE_ID    ?= com.google.ios.youtube

# Подпись: NO — результат ставится/подписывается Feather'ом.
CODESIGN_IPA    = 0
REMOVE_EXTENSIONS = 0
FINALPACKAGE    = 1

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 YouTube || true"
