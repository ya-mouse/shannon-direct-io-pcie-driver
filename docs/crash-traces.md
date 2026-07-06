# Shannon driver — crash traces & gdb recipe (6.8.0 / noble)

Reference material for debugging `shannon.ko` on the 6.8.0 kernel. Kept
in-tree so the agent does not depend on any external directory. The traces
below were captured during bring-up on noble `6.8.0-4x-generic` inside a QEMU
guest with the Shannon device passed through via vfio-pci.

## GDB recipe (attach to the QEMU gdb stub)

Boot QEMU with `scripts/qemu-shannon-run.sh ... --gdb` (adds `-gdb tcp::3333`
and `nokaslr`). Forward the port and attach:

```
ssh -L 3333:localhost:3333 <host>
gdb vmlinuz-<kver>                 # or a vmlinux with debug symbols
(gdb) target remote :3333
(gdb) continue
```

After the initrd `insmod`s the module, get its `.text` base from the guest:

```
# in the guest:
cat /proc/modules | grep shannon
#   shannon 4666184 0 - Live 0xffffffffc0201000 (O)

# in gdb:
(gdb) add-symbol-file shannon.ko 0xffffffffc0201000
```

Useful early breakpoint anchor (from a 6.8.0-48 trace):

```
(gdb) b local_pci_probe
(gdb) b shannon_probe            # 0xffffffffc022cfb9 in the trace below
(gdb) b shannon_init_hardware    # 0xffffffffc02274ec
(gdb) b get_pci_info             # 0xffffffffc026ea90
(gdb) b shannon_printk           # 0xffffffffc026c290
```

A captured probe backtrace (healthy path, just showing the call shape):

```
[   16.445229]  ? get_pci_info+0x11/0xf0 [shannon]
[   16.445605]  ? pci_read_config_dword+0x27/0x50
[   16.445828]  get_pci_bus_info+0x16/0x30 [shannon]
[   16.446307]  shannon_init_hardware+0x8d/0x94f [shannon]
```

`shannon_probe` calls `shannon_init_hardware` at `+3955`:

```
0xffffffffc022df2c <+3955>: call 0xffffffffc02274ec <shannon_init_hardware>
```

## Normal startup sequence (healthy, ~5+ minutes)

Expect this on a 6.4 TB G3i device. Do **not** run I/O until both `Attached`
and `Probed` appear.

```
shn_info: dfd: get 0 available mbr information.
shn_info: retry to read mbr in 4k mode.
shn_info: get mbr information successfully. max_update=22.
shn_info: sctd: flash id: 000000a954e5a42c
shn_info: sctd: ifmode: 3, overdrive: 0, freqmode: 0
shn_info: sctd: HAL version: 8, T: 35
shn_info: dfd: clk = 5.
shn_info: dfd: power_budget=0xf.
shn_info: dfd: max_available_luns=256, max_available_groups=8.
shn_info: dfd: start recover epilog head. ... done.
shn_info: dfd: start recover map table.
shn_info: dfd: try to slowpath recover map table(0x12).
shn_info: dfd: start recover epilog.
shn_info: dfd: recover 100 superblock's epilog done.     # ~25s per 100
shn_info: dfd: recover 200 superblock's epilog done.
...                                                          # ~3.5-4 min total
shn_info: dfd: recover 1000 superblock's epilog done.
shn_info: dfd: recover epilog done.
shn_info: dfd: start recover hot active super block.
shn_info: dfd: start recover cold active super block.
shn_info: recover active super blocks done.
shn_info: refresh_sequence=10.
shn_info: dfd: mbr_update=0x17.
shn_info: sctd: readwrite, readonly_reason= 0, reduced_write_reason= 0.
shn_warn: shannon_hwmon_init(): sctd: hwmon_device_register failed!   # non-fatal
shn_log: sctd: cannot initialize hwmon devices, move on.
shn_dbg: shannon_attach_sdev(): sdev=... name=sctd logicb_size=4096.
shn_dbg: shannon_alloc_disk(): ...
shn_dbg: shannon_init_gendisk(): disk_name=dfd, major=251, minors=64, ...
shn_dbg: shannon_set_capacity(): disk=... size=12500000768
 Dev dfd: unable to read RDB block 8
 dfd: unable to read partition table
shn_info: Attached Direct-IO PCIe Flash /dev/sctd as block device /dev/dfd:
shn_info: sector size: logical 512 / physical 4096, capacity: 6400 GB, overprovision: 22.58%.
shn_info: Probed Direct-IO PCIe Flash /dev/sctd: model: Direct-IO G3i-Ali 6400G, sn: SF17412K7520087
```

## Crash #1 — `blk_throtl_register` BUG (during `device_add_disk`)

Symptom: kernel BUG while adding the disk. The 6.8 block layer rejects the
queue because the wrapper's queue-limit / blk-mq setup is stale. Look in
`shannon_block.c` (`shannon_create_blkqueue`, `shannon_blk_queue_*`,
`shannon_init_gendisk`, `shannon_add_disk`) and `shannon_module_init.c`
(`block_device_operations`, `shannon_submit_bio`).

```
[  298.337491] shn_dbg: shannon_init_gendisk(): disk_name=dfa, major=251, minors=64, first_minor=0.
[  298.341171] ------------[ cut here ]------------
[  298.341446] kernel BUG at block/blk-throttle.c:2432!
[  298.342626] invalid opcode: 0000 [#1] PREEMPT SMP NOPTI
[  298.342701] CPU: 7 PID: 162 Comm: insmod Tainted: G  OE  6.8.0-47-generic #47-Ubuntu
[  298.342701] Hardware name: QEMU Standard PC (i440FX + PIIX, 1996), BIOS 1.13.0-1ubuntu1.1 04/01/2014
[  298.342701] RIP: 0010:blk_throtl_register+0xa5/0xd0
[  298.342701] Call Trace:
[  298.342701]  <TASK>
[  298.342701]  ? show_regs+0x6d/0x80
[  298.342701]  ? die+0x37/0xa0
[  298.342701]  ? do_trap+0xd4/0xf0
[  298.342701]  ? do_error_trap+0x71/0xb0
[  298.342701]  ? blk_throtl_register+0xa5/0xd0
[  298.342701]  ? exc_invalid_op+0x52/0x80
[  298.342701]  ? blk_throtl_register+0xa5/0xd0
[  298.342701]  ? asm_exc_invalid_op+0x1b/0x20
[  298.342701]  ? blk_throtl_register+0xa5/0xd0
[  298.342701]  blk_register_queue+0x133/0x220
[  298.342701]  device_add_disk+0x205/0x420
[  298.342701]  shannon_add_disk+0x19/0x60 [shannon]
[  298.342701]  shannon_attach_sdev+0xfa/0x202 [shannon]
[  298.342701]  shannon_attach+0x129/0x169 [shannon]
[  298.342701]  shannon_probe+0x23e6/0x27bb [shannon]
[  298.342701]  shannon_probe_wrapper+0x2b/0x40 [shannon]
[  298.342701]  local_pci_probe+0x47/0xb0
[  298.342701]  pci_call_probe+0x55/0x1a0
[  298.342701]  pci_device_probe+0x84/0x120
[  298.342701]  really_probe+0x1c7/0x410
[  298.342701]  __driver_probe_device+0x8c/0x180
[  298.342701]  driver_probe_device+0x24/0xd0
[  298.342701]  __driver_attach+0x10b/0x210
[  298.342701]  ? __pfx___driver_attach+0x10/0x10
[  298.342701]  bus_for_each_dev+0x8d/0xf0
[  298.342701]  driver_attach+0x1e/0x30
[  298.342701]  bus_add_driver+0x14e/0x290
[  298.342701]  driver_register+0x5e/0x130
[  298.342701]  __pci_register_driver+0x5e/0x70
[  298.342701]  shannon_init+0x14d/0xff0 [shannon]
```

## Crash #2 — `shannon_convert_bio` NULL deref (during `mkfs.xfs`)

Symptom: NULL pointer dereference in the bio-conversion path while `mkfs.xfs`
issues bios. A field moved/was removed in the 6.8 `bio` API (`bi_iter`,
`bi_bdev->bd_disk`, `bi_vcnt`, `bio_for_each_segment`). Fix in
`shannon_block.c` (`shannon_convert_bio`, `shannon_make_request`).

```
[  791.180735] BUG: kernel NULL pointer dereference, address: 000000000000000c
[  791.181756] #PF: supervisor read access in kernel mode
[  791.182781] #PF: error_code(0x0000) - not-present page
[  791.183681] PGD 0 P4D 0
[  791.184707] Oops: 0000 [#1] PREEMPT SMP NOPTI
[  791.185760] CPU: 43 PID: 1829 Comm: mkfs.xfs Tainted: G  OE  6.8.0-49-generic #49-Ubuntu
[  791.186874] Hardware name: Lenovo ThinkServer RD452X /B800G3-Y, BIOS A2.25 04/17/2017
[  791.188159] RIP: 0010:shannon_convert_bio+0x110/0x530 [shannon]
[  791.189950] Code: 41 8b 74 24 30 85 d2 75 0f e9 82 00 00 00 49 0f a3 fe 73 65 85 d2 74 78 49 8b 44 24 78 44 89 d9 41 89 da 48 c1 e1 04 48 01 c8 <8b> 78 0c 8b 40 08 01
[  791.192899] RSP: 0018:ffffc11001f37958 EFLAGS: 00010246
[  791.193310] RAX: 0000000000000000 RBX: 0000000000001000 RCX: 0000000000000000
[  791.193630] RDX: 0000000004000000 RSI: 0000000000000000 RDI: 0000000000001000
[  791.195426] RBP: ffffc11001f379c8 R08: ffff9fed56dcad80 R09: 0000000004000000
[  791.197069] R10: 0000000000001000 R11: 0000000000000000 R12: ffff9feb9072d000
[  791.198835] R13: 0000000000000000 R14: 0000000000000228 R15: ffff9fed56dcad80
[  791.200626] FS:  0000790da550e980(0000) GS:ffffa068ff380000(0000) knlGS:0000000000000000
[  791.202460] CS:  0010 DS: 0000 ES: 0000 CR0: 0000000080050033
[  791.204405] CR2: 000000000000000c CR3: 00000007dbae0004 CR4: 00000000003706f0
[  791.206522] Call Trace:
[  791.210775]  <TASK>
[  791.212768]  ? show_regs+0x6d/0x80
[  791.214932]  ? __die+0x24/0x80
[  791.217072]  ? page_fault_oops+0x99/0x1b0
[  791.219350]  ? do_user_addr_fault+0x2e2/0x670
[  791.221618]  ? exc_page_fault+0x83/0x1b0
[  791.223805]  ? asm_exc_page_fault+0x27/0x30
[  791.226140]  ? shannon_convert_bio+0x110/0x530 [shannon]
[  791.227780]  ? shannon_convert_bio+0xa6/0x530 [shannon]
[  791.229040]  shannon_make_request+0xe4/0x3f0 [shannon]
[  791.231712]  ? lock_timer_base+0x3b/0xe0
[  791.234132]  shannon_submit_bio+0x1d/0x30 [shannon]
[  791.236684]  __submit_bio+0xe4/0x1c0
[  791.238980]  __submit_bio_noacct+0x90/0x230
[  791.241582]  submit_bio_noacct_nocheck+0x1ac/0x1f0
[  791.243918]  ? bio_associate_blkg+0x3d/0x80
[  791.245097]  submit_bio_noacct+0x162/0x5b0
[  791.246757]  submit_bio+0xb2/0x110
```

## Crash #3 — `check_pending_command_queue` timeout alarm (after long runtime)

The device probes cleanly (startup sequence above completes), then hours later
the core's command-queue watchdog fires: `cq_tail == cq_head` and no progress
for `timeout` ms. Usually means IRQ/MSI-X delivery is broken on this kernel
(the card completed nothing) or `submit_bio`/`make_request` stalled. Check
`shannon_pci.c` MSI-X setup (`pci_alloc_irq_vectors` vs the legacy
`pci_enable_msix` path) and confirm the guest sees Shannon IRQs
(`cat /proc/interrupts | grep shannon`).

```
[Thu Jul  2 19:29:41 2026] shn_info: Attached Direct-IO PCIe Flash /dev/sctd as block device /dev/dfd:
[Thu Jul  2 19:29:41 2026] shn_info: Probed Direct-IO PCIe Flash /dev/sctd: model: Direct-IO G3i-Ali 6400G, sn: SF17412K7520087
... ~1.5 hours later ...
[Thu Jul  2 20:52:17 2026] shn_alarm: check_pending_command_queue(): scta: lunset=0, \
  cq_tail_tmp=0x398, cq_tail=0x398, cq_head=0x398, sq_head=0x350, hw_cq_head=0x398, \
  last_active_time=4300384451, original cq_tail=0x398, last_active_time=4300384451, \
  curr_time=4300420608, timeout=36157ms.
```
