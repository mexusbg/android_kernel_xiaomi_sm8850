# hma-uidfake, built-in. policy.c is #included by hooks.c (not a separate obj).
obj-$(CONFIG_HMA_UIDFAKE) += hma_uidfake.o
hma_uidfake-objs := main.o patch.o hooks.o lsm.o netlink.o
ccflags-y += -I$(src)
