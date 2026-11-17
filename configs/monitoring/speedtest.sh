#!/usr/bin/env bash
# speedtest.sh — run an Ookla speedtest and export the result to the node_exporter textfile
# collector. Cron on the PI every 2h (a speedtest saturates the WAN for ~30s — do NOT run it
# often, and not on a schedule that clashes with backups). Measures the Pi's path to the
# internet, which is representative of the whole LAN.
#
# Needs the Ookla 'speedtest' CLI + jq. Install once on the Pi:
#   curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
#   apt-get install -y speedtest
# (the free 'speedtest-cli' python package also works but is less accurate — then swap the
#  command below for: speedtest-cli --json  and read .download/.upload/.ping instead.)
set -euo pipefail

OUT="/var/lib/node_exporter/textfile_collector/speedtest.prom"
TMP="${OUT}.$$"
mkdir -p "$(dirname "$OUT")"

# Ookla CLI: bandwidth is BYTES/sec -> *8 for bits/sec. Flags skip the interactive licence prompt.
if ! j="$(speedtest --format=json --accept-license --accept-gdpr 2>/dev/null)"; then
  echo "speedtest failed (CLI installed? WAN up?)" >&2
  exit 1
fi

dl="$(jq -r '.download.bandwidth * 8'      <<<"$j")"
ul="$(jq -r '.upload.bandwidth * 8'        <<<"$j")"
ping="$(jq -r '.ping.latency'              <<<"$j")"
jit="$(jq -r '.ping.jitter // 0'           <<<"$j")"
loss="$(jq -r '.packetLoss // 0'           <<<"$j")"

{
  echo "# HELP speedtest_download_bits_per_second Download throughput (Ookla)."
  echo "# TYPE speedtest_download_bits_per_second gauge"
  echo "speedtest_download_bits_per_second ${dl}"
  echo "# HELP speedtest_upload_bits_per_second Upload throughput (Ookla)."
  echo "# TYPE speedtest_upload_bits_per_second gauge"
  echo "speedtest_upload_bits_per_second ${ul}"
  echo "# HELP speedtest_ping_latency_ms Idle latency to the test server."
  echo "# TYPE speedtest_ping_latency_ms gauge"
  echo "speedtest_ping_latency_ms ${ping}"
  echo "# HELP speedtest_jitter_ms Latency jitter during the test."
  echo "# TYPE speedtest_jitter_ms gauge"
  echo "speedtest_jitter_ms ${jit}"
  echo "# HELP speedtest_packet_loss_percent Packet loss during the test."
  echo "# TYPE speedtest_packet_loss_percent gauge"
  echo "speedtest_packet_loss_percent ${loss}"
  echo "# HELP speedtest_last_run_timestamp_seconds When the last speedtest completed."
  echo "# TYPE speedtest_last_run_timestamp_seconds gauge"
  echo "speedtest_last_run_timestamp_seconds $(date +%s)"
} > "$TMP"
mv "$TMP" "$OUT"
echo "speedtest: wrote $OUT (down=${dl} up=${ul} bits/s, ping=${ping}ms)"
