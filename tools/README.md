KernelPatch verification tools (kptools-linux, kpimg-linux)
===========================================================

The binaries are NOT committed to this repository; .gitignore excludes them.
Download the release that matches the APatch app installed on the device
(0.13.9 was used for the verification recorded in NOTES.txt):

  https://github.com/bmax121/KernelPatch/releases

Then either unpack them here as tools/kptools-linux and tools/kpimg-linux,
or point the verifier at them explicitly:

  KPTOOLS=/path/to/kptools-linux scripts/verify-patch.sh

scripts/verify-patch.sh also falls back to /tmp/opencode/kp/ (the location used
during the original build) and requires kpimg-linux to sit next to kptools.

The tools are part of KernelPatch, which is licensed under GPL-2.0.
