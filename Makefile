# KERNELRELEASE is set by the kernel build system.  This is used
# as a test to know if the build is being driven by the kernel.
ifneq ($(KERNELRELEASE),)
# Kernel build

# Older kernel scripts/Makefile.build only process Makefile so
# we include the Kbuild file here.  Newer kernel scripts/Makefile.build
# include Kbuild directly and never process Makefile (this file).
include $(SHANNON_DRIVER_DIR)/Kbuild

else

KERNELVER ?= $(shell uname -r)
KERNEL_SRC = /lib/modules/$(KERNELVER)/build

GCC_FALLTHROUGH_OPTION = $(shell echo "" | gcc -fsyntax-only -Wno-implicit-fallthrough -xc - 2>&1)
ifeq ($(GCC_FALLTHROUGH_OPTION),)
SHANNON_FLAGS += -Wno-implicit-fallthrough
endif

# Uncomment this to build EMU module directly in this dir.
#SHANNON_FLAGS += -DCONFIG_SHANNON_EMU_MODULE

.PHONY: all shipped clean modules_clean modules modules_install uninstall
all: shipped modules

SHIPPED_OBJS := $(wildcard *.o_shipped)
TARGET_OBJS := $(SHIPPED_OBJS:.o_shipped=.o)

KVER_MAJOR := $(shell echo $(KERNELVER) | cut -d. -f1)
KVER_MINOR := $(shell echo $(KERNELVER) | cut -d. -f2)

ifeq ($(shell test "$(KVER_MAJOR)" -ge 6 -o \( "$(KVER_MAJOR)" -eq 5 -a "$(KVER_MINOR)" -ge 15 \); echo $$?),0)
OBJDUMP_REDEF := --redefine-sym printk=_printk
endif

shipped: $(TARGET_OBJS)

%.o: %.o_shipped
	objcopy $(OBJDUMP_REDEF) \
		--weaken-symbol shannon_attach_sdev \
		$< $@
	truncate -s 0 .$@.cmd

clean modules_clean:
	$(MAKE) \
	    -C $(KERNEL_SRC) \
	    SHANNON_DRIVER_DIR=$(shell pwd) \
	    M=$(shell pwd) \
	    clean

debug:
	$(MAKE) \
	    -C $(KERNEL_SRC) \
	    SHANNON_DRIVER_DIR=$(shell pwd) \
	    M=$(shell pwd) \
	    CONFIG_BLK_DEV_SHANNON=m \
	    CONFIG_SHANNON_EMU= \
	    EXTRA_CFLAGS="$(SHANNON_FLAGS)" \
	    INSTALL_MOD_PATH=$(INSTALL_ROOT) \
	    modules

modules modules_install:
	$(MAKE) \
	    -C $(KERNEL_SRC) \
	    SHANNON_DRIVER_DIR=$(shell pwd) \
	    M=$(shell pwd) \
	    CONFIG_BLK_DEV_SHANNON=m \
	    CONFIG_SHANNON_EMU= \
	    EXTRA_CFLAGS="$(SHANNON_FLAGS) -DSHANNON_RELEASE" \
	    INSTALL_MOD_PATH=$(INSTALL_ROOT) \
	    $@
uninstall:
	@echo "DELETE /lib/modules/$(KERNELVER)/extra/shannon.ko"
	@rm -rf /lib/modules/$(KERNELVER)/extra/shannon.ko
	@echo "DEPMOD $(KERNELVER)"
	@/sbin/depmod $(KERNELVER)

endif
