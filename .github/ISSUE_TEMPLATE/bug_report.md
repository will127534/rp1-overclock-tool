---
name: Bug report
about: Something went wrong installing or running the overlay
title: ''
labels: bug
---

## What happened

<!-- One or two sentences. -->

## Environment

```
# uname -r output
$ uname -r


# Pi model + revision
$ cat /proc/device-tree/model; echo
$ grep ^Revision /proc/cpuinfo


# RP1 chip_id from dmesg
$ dmesg | grep -i "rp1.*chip_id"
```

## Live device-tree clock layout

```
$ od -An -tx4 --endian=big \
    /sys/firmware/devicetree/base/axi/pcie@1000120000/rp1/clocks@18000/assigned-clocks


$ od -An -tx4 --endian=big \
    /sys/firmware/devicetree/base/axi/pcie@1000120000/rp1/clocks@18000/assigned-clock-rates
```

## Generator output

```
$ ./install.sh --dry-run
```

<!-- Paste the full output, including stderr. The .dts block at the end is the
most important part for debugging clock-binding shifts. -->

## What you expected

<!-- e.g. "clk_sys at 333 MHz after reboot, but it's still 200 MHz" -->
