# configs/nut — UPS / graceful shutdown (H1) [R22]

NUT shuts every box down in order before the battery dies, so a mid-write power cut
is a clean stop, not an aborted journal. **Everything that writes goes on the UPS:**
both NUCs, the DAS, the Pi (sole DNS, on an SD card — the classic corruption case),
and the USB HDD (PBS writes to it mid-backup).

Topology: the host the UPS USB plugs into runs NUT as **master** (`MODE=netserver`);
the other NUC, the Pi and the PBS VM run as **netclients** (`MODE=netclient`) so each
shuts down gracefully.

Shutdown order must match the G3 manual reverse order: **services → storage → DNS last.**

Files (examples here — copy to /etc/nut/ and fill, they are not secrets but are host-specific):
- `ups.conf.example`      — the UPS driver/port on the master
- `upsmon.conf.example`   — MONITOR lines + SHUTDOWNCMD
- `upssched.conf.example` — timers (optional: early shutdown on low runtime)

Size the UPS for the time to stop Frigate + PBS and unmount mergerfs before the
battery dies. A GPU node (Stage I) blows this budget — it's "shut down first", not protected.
