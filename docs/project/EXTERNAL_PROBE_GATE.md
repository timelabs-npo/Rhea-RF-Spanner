# G3: first external radio probe gate

**Design only — 2026-11-08.** This gate selects an initial instrument adapter;
it does not add networking, firmware, a supported device, or a release claim.
G1 audio and G2 spatial-context validation remain separate work.

The coordinator's WD PnP-name check at `2026-11-08T02:48:20Z`
(05:48:20 Europe/Moscow) found no matching ESP, Flipper, CP210, CH340 or Beryl
name among present devices. This observation does not identify the available
hardware and does not exclude a network-connected probe. **No network discovery
was performed.** Actual board, firmware and connection details are prerequisites.

## Documented capability versus the adapter still to prove

| Device | Officially documented boundary | What remains unverified for Rhea |
| --- | --- | --- |
| **ESP32-S3** | The chip supports **2.4 GHz IEEE 802.11b/g/n**; it is not a 5 GHz receiver. ESP-IDF documents packet-derived channel-state information (CSI), including complex subcarrier values and packet-dependent layouts. [Datasheet][esp-chip], [CSI guide][esp-csi] | The owned board/module and antenna, firmware build, actual CSI delivery, timestamp behavior, supported packet layouts, scaling and sustained loss rate. No calibrated spectrum or coherent ranging result is established. |
| **Flipper Zero** | Its built-in CC1101/antenna covers **300–348, 387–464 and 779–928 MHz**. The Sub-GHz application includes decoded reception and RAW recording. [Hardware/application][flipper] | A verified read/export path and actual firmware version. Its Sub-GHz output must not be advertised as Wi-Fi CSI or broadband SDR I/Q. A Wi-Fi accessory would be a separate adapter with separate evidence. |
| **GL-MT3000 Beryl AX** | GL.iNet documents **2.4/5 GHz Wi-Fi** and an OpenWrt-based router; the administration guide exposes band, channel and bandwidth settings. [Product][beryl], [Guide][beryl-guide] | The installed firmware/kernel/driver and available measurement interfaces. Dual-band connectivity does not establish a CSI, raw-I/Q or calibrated spectrum API. Inspect the actual supported export before promising measurements. |

Flipper RAW `.sub` records have frequency/preset metadata and signed signal
durations in **microseconds**. These are a different quantity from complex RF
samples. A later bounded Flipper task can first import a user-selected recording
and preserve its modulation/preset and timing semantics. Live export requires
its own demonstrated transport. [Official file format][flipper-format]

## First adapter decision

Prioritize **an ESP32-S3 receiver with an ESP-IDF CSI firmware profile**, named
`esp32s3-csi-v1`. The reference API target is the versioned **ESP-IDF v6.1**
documentation below; the actual SDK commit, firmware source/build hash,
`sdkconfig`, board/module and antenna must be pinned before a physical claim.
This is a selected implementation target, not confirmation that a matching
board is connected.

Start with one owned test access point, one receiver, one fixed **2.4 GHz /
20 MHz** configuration and one declared transmitter/link. The first useful
product is a repeatable link-observation timeline: received-packet RSSI,
subcarrier response, observed delivery rate, missing data and configuration.
It can support controlled before/after comparisons while keeping changes in
placement, traffic and radio settings visible.

ESP-IDF supplies `esp_wifi_set_csi_rx_cb`, `esp_wifi_set_csi_config` and
`esp_wifi_set_csi`. CSI includes signed imaginary/real byte pairs; LTF sections
and their lengths depend on packet/configuration metadata, and
`first_word_invalid` can invalidate the first four bytes. Preserve that flag and
the original layout. The callback runs in the Wi-Fi task; copy bounded data to
a queue and process elsewhere. Its supplied storage expires after the callback.
[CSI guide][esp-csi], [API/lifetime contract][esp-api]

The proposed firmware uses station-mode reception from the configured test
access point. Record the ordinary test traffic used to produce packets;
do not describe an associated Wi-Fi receiver as radio-silent. Keep per-packet
channel responses distinct from calibrated noise density, absolute RF phase,
distance, interferer identity or a universal “RF cleanliness” score.

## Typed observation contract

Use a separate versioned envelope and typed payload. Keep the existing acoustic
64-byte Replay format unchanged. A scalar Float ring or a universal 32-byte
carrier packet cannot preserve CSI dimensions, packet metadata and validity.

| Contract field | Required meaning |
| --- | --- |
| Identity and provenance | Schema version, adapter profile, firmware/SDK identity, session/boot epoch, source alias, and `measured`, `replay` or `synthetic` provenance. Separate the receiver identity from the observed transmitter/link. |
| Radio configuration | Actual channel/center frequency in Hz, bandwidth in Hz, antenna/chain, PHY/LTF layout and relevant filtering/scaling settings. Changed configuration begins a new segment. |
| Quantity and units | CSI integer complex values with explicit component order and subcarrier indices; RSSI only in the SDK-declared unit after checking the pinned implementation. Unknown scale stays unknown; raw counts do not become volts, dBm or dBFS. |
| Time | Sensor clock identifier, tick unit/width, capture semantics, wrap/reset rules and validity. Keep receiver time, callback receipt and iPhone arrival separate. Reconnect/reboot changes the epoch; no inferred shared clock. |
| Integrity | Sequence number, payload byte length, element count, validity mask and invalid-prefix metadata. Bound counts before allocating or decoding; reject incompatible required versions and malformed lengths. |
| Loss and quality | Separate firmware queue drops, transport loss, decoder rejection, stale records and missing CSI. A gap in our export sequence is not proof of over-air packet loss. That needs a known transmitted sequence and a defined receiver experiment. |

SDK metadata such as RSSI, noise-floor fields, receive time and antenna exists in
the CSI receive information, but field availability and meaning must be checked
against the selected target/header and captured values. Expose absent or
unvalidated metrics as unavailable. [CSI metadata][esp-csi]

Use a typed bounded queue outside the audio callback. Reuse display and recording
infrastructure only after units, timing and validity match. A future RF estimator
must supply its own model; the acoustic speed-of-sound displacement conversion
does not apply. Phone AR pose also does not locate a separately moving probe.
Spatial registration requires a demonstrated time relationship and probe-to-phone
mount/transform, or an independent probe pose; otherwise observations remain
spatially unassociated.

## Proposed connection and storage behavior

First preserve a firmware-side recorded fixture over the confirmed workstation
connection. This establishes the parser contract without claiming direct iPhone
USB-serial support. Then implement one **authenticated, length-delimited local
stream** between the paired probe and app. This transport is a proposal, not a
vendor feature or completed protocol. Choose and review its authentication,
framing and bounded backpressure before deployment. If UDP is later justified,
retain sequence/loss accounting and explicit fragment/reassembly limits.

The user selects **External probe**, confirms its identity and capabilities,
then explicitly connects and starts. No background discovery or automatic
capture on launch. Stop, disconnect, backgrounding and the existing foreground
run limit invalidate live observations; stale history stays labelled. Pairing
secrets belong in protected storage. Default diagnostics contain aggregate
health, not SSIDs, MAC addresses, credentials or captured packet payloads.
Dataset recording is a separate explicit action with its own content/retention
description.

Before local networking is integrated, add the purpose string required by
Apple's `NSLocalNetworkUsageDescription` guidance and test permission denial.
Bonjour registration/browsing additionally needs declared service types; do
not add it merely to populate a device list. [Apple local-network privacy][apple-local]

## Bounded implementation slices and acceptance

1. **Inventory and firmware fixture.** Identify the actual board and supported
   connection; freeze SDK/firmware/configuration and test-link settings. Retain
   an actual capture plus manifest/hash. Verify payload layout, invalid bytes,
   units and clock behavior. Until then, fixtures remain explicitly synthetic.
2. **Offline decoder.** Build only the typed envelope/decoder and fixture tests.
   Cover wrong version, truncated/oversized payload, unknown layout, invalid
   prefix, duplicate/out-of-order sequence, queue overflow, timestamp wrap,
   reset and disconnection. Reproduce firmware values without fabricating gaps.
3. **One paired live view.** Add the confirmed transport and explicit controls.
   Show source, band/channel, measured quantities, age and losses. Compare a
   short foreground run against the firmware-side log; account for every
   accepted, dropped or rejected record. Transport traffic shares the survey
   environment, so retain its configuration and measure its effect.
4. **Physical acceptance.** Repeat stationary and controlled moved-receiver
   trials with the same transmitter/settings; retain actual variation and
   unexecuted checks. Verify Stop, denial, unplug/reboot and reconnect behavior.
   Pin app/firmware/build identities. Software fixtures and attractive maps do
   not close this gate; agreement with recorded probe output does not establish
   calibrated field accuracy.

Beryl can later supply verified router counters or serve as the controlled AP;
Flipper can supply its own typed Sub-GHz observations. Each receives a separate
capability/fixture gate. No first adapter is required to impersonate the others.

[esp-chip]: https://documentation.espressif.com/esp32-s3_datasheet_en.pdf
[esp-csi]: https://docs.espressif.com/projects/esp-idf/en/v6.1/esp32s3/api-guides/wifi-driver/wifi-vendor-features.html
[esp-api]: https://docs.espressif.com/projects/esp-idf/en/v6.1/esp32s3/api-reference/network/esp_wifi.html
[flipper]: https://docs.flipper.net/zero/sub-ghz
[flipper-format]: https://developer.flipper.net/flipperzero/doxygen/subghz_file_format.html
[beryl]: https://www.gl-inet.com/products/gl-mt3000/
[beryl-guide]: https://docs.gl-inet.com/router/en/4/user_guide/gl-mt3000/
[apple-local]: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
