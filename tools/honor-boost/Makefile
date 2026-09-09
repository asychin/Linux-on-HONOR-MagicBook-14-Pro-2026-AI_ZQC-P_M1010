obj-m += honor-ec-rail.o

# This kernel is built with clang (cachyos); build modules with LLVM=1.
KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) LLVM=1 -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) LLVM=1 -C $(KDIR) M=$(PWD) clean
