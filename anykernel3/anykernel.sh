### AnyKernel3 Ramdisk Mod Script
## configured for Xiaomi earth (Redmi 12C / POCO C55, MT6768)
## APatch / KernelPatch base kernel - no KernelSU, no SukiSU

### AnyKernel setup
# global properties
properties() { '
kernel.string=earth 4.19.325 APatch-ready kernel (MT6768)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=earth
device.name2=aether
device.name3=Redmi 12C
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
# Note: this LineageOS recovery-as-boot ramdisk has no /sbin at all, so the
# upstream AK3 line "set_perm_recursive ... $RAMDISK/sbin" would print a
# "find: .../sbin: No such file or directory" error.  Only touch init*.
set_perm_recursive 0 0 750 750 $RAMDISK/init*;
} # end attributes

# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
# 0 = never touch vbmeta.  The bootloader is unlocked, so AVB is not enforced,
# and we cannot re-sign anything (no vendor key).  Keeping magiskboot away from
# vbmeta/flags avoids writing to a partition we did not model.
PATCH_VBMETA_FLAG=0;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install: keep the LineageOS ramdisk untouched, only replace the kernel
dump_boot;
write_boot;
## end boot install
