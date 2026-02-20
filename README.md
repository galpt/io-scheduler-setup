# IO Scheduler Setup

Small interactive helper to inspect and set block device I/O schedulers,
and persist a chosen scheduler across reboots using a udev rule.

---

## Table of Contents
- [Status](#status)
- [Features](#features)
- [Requirements](#requirements)
- [Usage](#usage)
- [Examples](#examples)
- [Design Notes](#design-notes)
- [Limitations & Next Steps](#limitations--next-steps)
- [Contributing](#contributing)
- [License](#license)

## Status
- Basic interactive script saved at `io-scheduler-setup.sh`. Intended for
  manual use on systems where `/sys/block/<dev>/queue/scheduler` is writable.

## Features
- Enumerates block disks with `lsblk` and shows model/size/rotational flag.
- Reads available schedulers from `/sys/block/<dev>/queue/scheduler`.
- Applies a scheduler immediately (writes to sysfs).
- Optionally writes a udev rule at `/etc/udev/rules.d/99-io-scheduler.rules`
  to make the scheduler selection persistent across reboots.
  The `99-` prefix ensures this rule runs after all system defaults
  (e.g. `60-ioschedulers.rules` from systemd-udev which resets NVMe to `none`).
- Provides `--remove <dev>` to remove rules created for a device.

## Requirements
- A Linux kernel and distribution that expose `/sys/block/<dev>/queue/scheduler`.
- `bash`, `lsblk`, `udevadm`, and basic shell utilities (`awk`, `sed`, `grep`).
- Root privileges to write sysfs and to create udev rules (script will escalate via `sudo`).

## Usage
1. Make the script executable from the `IO Scheduler Setup` directory:

```bash
chmod +x io-scheduler-setup.sh
```

2. Run interactively (recommended):

```bash
sudo ./io-scheduler-setup.sh
```

3. Remove previously created udev rules for a device:

```bash
sudo ./io-scheduler-setup.sh --remove sda
```

> [!NOTE]
> - Persistent udev rules are written to `/etc/udev/rules.d/99-io-scheduler.rules`.
> - The `99-` prefix guarantees this file is processed after system defaults that would otherwise override your choice.
> - The script backs up an existing rule file before appending new entries.

## Examples
- Inspect disks and set scheduler interactively:

```bash
sudo ./io-scheduler-setup.sh
# follow prompts to choose disk, apply scheduler, and optionally persist it
```

- Create a persistent rule for `/dev/sdb` (example interactive flow):
  - Choose `/dev/sdb` in the menu
  - Apply desired scheduler (optional)
  - Choose to create persistent udev rule and enter the desired scheduler

## Design Notes
- The script prefers to match devices by their kernel name (e.g. `sda`) when
  writing udev rules: `SUBSYSTEM=="block", KERNEL=="sda", ATTR{queue/scheduler}=="<sched>"`.
- This keeps rules simple and predictable; for more advanced per-model rules
  you can edit the generated `/etc/udev/rules.d/60-io-scheduler.rules` manually.
- After writing rules the script reloads udev rules and triggers a change event
  for the affected device.

## Limitations & Next Steps
- Not all block devices allow changing the scheduler at runtime (some device/driver
  stacks ignore writes to `/sys/block/.../queue/scheduler`). If writing fails,
  the script reports the error.
- NVMe vs SATA: device naming differs (`nvme0n1` vs `sda`) — the script lists
  all block disks so pick the exact kernel name printed by the menu.
- Future improvements: add a dry-run mode, allow matching by WWN or model for
  more permanent device identification, and add unit tests or a validation
  mode that runs on non-root to show proposed changes.

## Contributing
- Bug reports and improvements welcome. Keep changes small and avoid running
  untrusted code as root. When modifying udev behavior, prefer clear, documented
  rules and make backups of `/etc/udev/rules.d/60-io-scheduler.rules`.

## License
- MIT
