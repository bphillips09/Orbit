# SXi protocol

This document describes the SXi protocol used by Orbit to control the SXV300 and InfoLink tuners over UART and UART-over-IP. 

It is based on reverse‑engineered implementation work in this repo, so details may be incomplete.

## Overview

- **Transport**: UART (serial), framed binary messages
- **High level**:
  - Host sends **commands** (tune, monitor, config, etc.)
  - Device sends **indications** (unsolicited updates like now‑playing, time, subscription)
  - Device may send **responses** or **errors** to host commands
  - Host must **ACK** most device indications

## Frame format

All traffic is exchanged as “frames” with a fixed header and a trailing 16‑bit checksum.

| Offset | Size | Field |
| --- | ---: | --- |
| `0x00` | 2 | SYNC = `0xDE 0xC6` |
| `0x02` | 1 | SEQ (`uint8`, 0–255) |
| `0x03` | 1 | TYPE (`uint8`, see “Payload types”) |
| `0x04` | 2 | LEN (`uint16`, big‑endian): payload length in bytes |
| `0x06` | LEN | PAYLOAD (`LEN` bytes) |
| `0x06+LEN` | 2 | CHECKSUM (`uint16`, big‑endian): checksum of bytes `0x00..(0x05+LEN)` |

### Payload types

Orbit treats the `TYPE` byte as:

| Value | Name | Notes |
| ---: | --- | --- |
| 0 | init | Link/bootstrapping only |
| 1 | control | Most SXi messaging (commands, indications, ACKs, responses) |
| 2 | data | Data services (i.e. SDTP packets for artwork/logos/EPG) |
| 3 | audio | Potentially unused, Orbit does not parse it |
| 4 | debug | Debug payloads (read/write/tunnel/monitor) |

### Checksum (16‑bit)

Orbit implements the device’s checksum algorithm. In pseudocode (matching `DeviceLayer.calculateChecksum()` / `DeviceMessage.calculateChecksum()`):

```text
check = 0
for byte in frame_without_checksum:
  check = (((check + byte) & 0xFF) * 0x100) + (check + byte) + 0x100
  check = ((check >> 16) ^ check) & 0xFFFF
```

## Payload format

Most payloads begin with a 3‑byte header:

```text
[ OPCODE_MSB ][ OPCODE_LSB ][ TRANSACTION_ID ][ PARAMS... ]
```

- **OPCODE**: `uint16` (big‑endian)
- **TRANSACTION_ID**: `uint8` “transaction id” used by the device/host for matching and ACKing
- **PARAMS**: opcode‑specific

### Special case: heartbeat payloads

Orbit treats any payload with length 2 bytes as a “heartbeat” payload. It doesn’t parse fields beyond that. Any received bytes update the link’s “last seen” timestamp, and a lack of traffic triggers disconnect/reconnect logic.

## Opcode classes

The top two bits of `OPCODE_MSB` classify the message:

| `OPCODE_MSB & 0xC0` | Class | Typical direction |
| --- | --- | --- |
| `0x00` | Command | Host to Device |
| `0x40` | ACK | Host to Device |
| `0x80` | Indication | Device to Host |
| `0xC0` | Response / Error | Device to Host |

Orbit’s runtime behavior follows this rule (see `SXiLayer.cycleState()`)

## ACK behavior

Most device indications require an explicit host ACK:

- **SEQ**: ACK uses the same sequence number as the indication
- **TYPE**: ACK is sent as `TYPE = control`
- **OPCODE**: ACK opcode is derived from the indicated opcode by setting the ACK class bits:

```text
ackOpcodeMsb = (origOpcodeMsb & 0x3F) | 0x40
ackOpcodeLsb =  origOpcodeLsb
```

- **TRANSACTION_ID**: copied from the indicated payload
- **ACK payload length**: Orbit constrains ACK payloads to ≤ 10 bytes

### Additional ACK payload requirement

For some indications, the device expects extra bytes appended to the ACK payload (beyond `[ackOpcode][transactionId]`):

- **Status** (`0x80A0`) and **Category info** (`0x8201`): append 1 byte:
  - Status: `statusMonitorItemID`
  - Category info: `catID`
- **Metadata indications**: append 2 bytes (the `SID` field)
  - Track metadata (`0x8300`)
  - Channel info (`0x8281`)
  - Channel metadata (`0x8301`)
  - Look‑ahead track metadata (`0x8303`)

This behavior is implemented in `SXiLayer.processIndication()` and is required. Without this, the module may not treat the message as acknowledged and will keep repeating it.

## Session flow (what Orbit does)

1. **Connect & init**
   - Open UART at 57600 and send an init frame (`TYPE=init`, `SEQ=0`) with payload bytes:
     - `OPCODE=0x0000`
     - `TRANSACTION_ID = baudCode` (host‑selected secondary baud, encoded as a small integer)
     - params: `[0x00]`
2. **Switch baud**
   - After receiving any valid device traffic, switch the host (and for UART‑over‑IP, the backend) to the desired secondary baud
3. **Configure / start monitors**
   - Send a sequence of commands to configure the module, tune to a default channel, and enable status/metadata/data monitors
4. **Normal operation**
   - Device streams indications (now playing, time, subscription, data services, etc)
   - Host ACKs indications and sends additional commands as requested by the UI

## Metadata (TMI / CMI / GMI)

Several indications contain a compact “metadata block” format. The pattern is:

```text
[ COUNT:uint8 ][ ITEM_0 ][ ITEM_1 ] ... [ ITEM_(COUNT-1) ]
```

Each item starts with a 16‑bit big‑endian tag:

```text
[ TAG_MSB ][ TAG_LSB ][ VALUE... ]
```

The value length/encoding depends on the tag. Orbit’s parsing logic lives in [`lib/metadata/metadata.dart`](../lib/metadata/metadata.dart).

### Track Metadata Items (TMI)

Known tags (see `TrackMetadataIdentifier`):

- `songId`, `artistId`, `itunesSongId`: 32‑bit big‑endian integer
- `songName`, `artistName`, `currentInfo`: null‑terminated string (decoded as UTF‑8, with fallbacks)
- Some tags are 1‑byte values (i.e. traffic/weather/sports ids)
- Some tags are lists (i.e. 32‑bit count followed by `uint16` entries)

### Channel Metadata Items (CMI)

Known tags (see `ChannelMetadataIdentifier`):

- `channelShortDescription`, `channelLongDescription`: null‑terminated string
- `similarChannelList`: 32‑bit count followed by `uint16` channel ids
- `channelListOrder`: `uint16`

### Global Metadata Items (GMI)

Known tags (see `GlobalMetadataIdentifier`) include a mix of:

- `uint8` values
- `uint16` values (big‑endian)
- null‑terminated strings
- lists with 32‑bit count followed by 1‑byte entries

## Data services (DSI/DMI) and SDTP

SXi has a “data plane” used for larger binary datasets (album art, channel logos/graphics, EPG, weather, etc.)

Orbit currently decodes some of these.

### DSI vs DMI

- **DSI** (Data Service Identifier): the logical data service (album art, channel graphics updates, EPG, weather, etc.). In code this is `DataServiceIdentifier` (see [`lib/sxi_indication_types.dart`](../lib/sxi_indication_types.dart))
- **DMI** (Data Multiplex Identifier): the transport channel id used in `0x8510` data packets. The device announces which DMIs belong to which DSI

### Service discovery: `0x8500` Data Service Status

Conceptually, the satellite carousel is always broadcasting many data services over the air to all tuners. The host does not receive all of that directly. Instead:

- The host tells the tuner which DSIs to monitor (subscribe to locally) via control commands
- The tuner filters the broadcast data stream and only passes through packets for the monitored DSIs
- If the tuner is not entitled to a data service (for example, not subscribed or subscription expired), it will not forward that service’s data even if the host requests monitoring
- Exceptions to this are "free to air" data, like weather station names, movie theater names, gas station names, etc.

When a data service is first monitored or the subscription to the data service changes, the device will send `0x8500` (`SXiDataServiceStatusIndication`) to announce which DMIs are currently carrying each DSI. The indication includes:

- `dsi` (16‑bit, big‑endian)
- `dmiCnt` (count)
- `dmi` (a byte list containing `dmiCnt` 16‑bit DMIs, big‑endian)

Orbit turns the DMI bytes into `uint16` values (MSB/LSB pairs) and builds a runtime mapping for DMI to DSI. If a `0x8510` packet arrives with a DMI that has no mapping yet, it is ignored

### Data packets: `0x8510` Data Packet Indication

When the device sends data, it uses `0x8510` (`SXiDataPacketIndication`) with fields:

```text
[ packetType:uint8 ][ dmi:uint16 ][ packetLen:uint16 ][ dataPacket:bytes... ]
```

`packetType` observed values (see `DataServiceType` in [`lib/sxi_command_types.dart`](../lib/sxi_command_types.dart)):

- `0`: SDTP (what Orbit handles now)
- `1`: XMApp (essentially XM-specific data)
- `2`: Raw data packet, not yet observed in SXi

For SDTP packets, Orbit parses `dataPacket` as an SDTP packet and reassembles it into a complete Access Unit (AU).

### SDTP packet format

In Orbit’s code ([`lib/data/sdtp.dart`](../lib/data/sdtp.dart)), an SDTP packet has:

```text
[ SDTP_HEADER:4 bytes ][ SDTP_DATA... ][ SDTP_CHECKSUM:1 byte ]
```

The 4‑byte SDTP header is bit‑packed:

- `byte0`: `sync` (8 bits)
- `byte1`:
  - `soa` (1 bit): Start Of Access Unit
  - `eoa` (1 bit): End Of Access Unit
  - `rfu` (2 bits)
  - `psi[9:6]` (4 bits)
- `byte2`:
  - `psi[5:0]` (6 bits)
  - `plpc[9:8]` (2 bits)
- `byte3`:
  - `plpc[7:0]` (8 bits)

Where:

- **PSI**: Packet Sequence Index (used for ordering if needed)
- **PLPC**: Payload Length in Packet Count (used by Orbit as “expected packet count minus 1” on SOA packets)

The trailing SDTP checksum is a 1‑byte sum (as implemented): sum of bytes `dataPacket[1..len-2]` (excluding the sync byte and excluding the trailing checksum), modulo 256.

### Access Unit (AU) reassembly + CRC32

Orbit accumulates SDTP packets per‑DMI:

- When `soa==1`, it starts a new AU for that DMI and records `expectedPackets = plpc + 1`.
- It appends each SDTP packet’s data bytes (everything after the SDTP header and before the SDTP checksum)
- When `eoa==1`, it concatenates all packet data and interprets the result as an Access Unit:
  - First 4 bytes: AU header
  - Last 4 bytes: CRC32 (big‑endian)
  - Middle bytes: AU payload

Orbit validates the AU’s CRC32 (standard CRC32 polynomial `0xEDB88320`, see [`lib/crc.dart`](../lib/crc.dart)) before dispatching the AU to a DSI-specific handler

### Album art (DSI `0x13B`)

Album art AUs are parsed at the bit level (see [`lib/data/handlers/album_art_handler.dart`](../lib/data/handlers/album_art_handler.dart)):

- Header:
  - `pvn` (4 bits): protocol version number
  - `carid` (3 bits): carousel id
    - `0` / `1`: image data
    - `2`: default assignment (not used by Orbit)
- Image payload:
  - `programType` (4 bits)
  - `imageType` (3 bits) — Orbit currently handles `0`
  - `sid` (10 bits)
  - `programId` (ARG) encoding depends on `programType`:
    - `programType==0`: read 32 bits, mask off sign bit (`& 0x7FFFFFFF`)
    - `programType==4`: read 8 bits and combine with `sid` to form a larger id (`programId |= sid << 16`)
  - optional caption block (1 bit + up to 5× 5‑bit chars)
  - optional extended data block (1 bit + length + bytes)
  - optional multi‑AU group framing:
    - `isAuGroup` (1 bit)
    - `fieldSize` (4 bits)
    - `accessUnitTotal` and `accessUnitCount` (each `fieldSize+1` bits)

If `isAuGroup` is set, Orbit collects all fragments and assembles the final image bytes in order 

The assembled bytes are treated as an opaque image blob (typically PNG/JPEG) and stored per `(sid, programId)`

### Channel graphics updates (DSI `0x137`)

Channel graphics AUs are also bit‑parsed (see [`lib/data/handlers/channel_graphics_handler.dart`](../lib/data/handlers/channel_graphics_handler.dart)):

- Header:
  - `pvn` (4 bits): protocol version number
  - `carid` (3 bits): carousel id
  - 1 reserved bit
  - `mti` (8 bits): message/type id

Orbit currently uses:

- **Service reference data** (`mti` in `{0x02,0x66,0x70,0x08,0x76,0x6C}`):
  - Provides a mapping from `sid` → `chanLogoId` (+ a sequence number).
  - Used so later “logo data” packets can be associated with channels
- **Channel graphics (logo) data** (`mti` in `{0x09,0x77}`):
  - Contains a `chanLogoId`, a validity section (including a sentinel byte `0x43` and a 32‑bit “validity field” where bit 6 must be set), followed by:
    - `imageDataLen` (16 bits)
    - `imageData` bytes
    - background color fields (RGB) and flags

Some parts of channel graphics updates were observed but chosen to not be implemented at this time, i.e. category background images and sports logos.

## Known commands (Host to Device)

Orbit can send the following command opcodes (implemented in [`lib/sxi_commands.dart`](../lib/sxi_commands.dart))

Most SXi commands are sent using payload type `control` in Orbit

| Opcode | Name (Orbit) | Typical payload type | Summary (very short) |
| --- | --- | --- | --- |
| `0x0020` | `SXiConfigureModuleCommand` | control | Module configuration (boot/limits) |
| `0x0021` | `SXiPowerModeCommand` | control | Power on/off |
| `0x0060` | `SXiConfigureTimeCommand` | control | Set timezone + DST mode |
| `0x00A0` | `SXiMonitorStatusCommand` | control | Start/stop status monitor items |
| `0x00A1` | `SXiMonitorFeatureCommand` | control | Start/stop feature monitors |
| `0x00A2` | `SXiMonitorExtendedMetadataCommand` | control | Start/stop metadata monitors (TMI/CMI/GMI) |
| `0x00E0` | `SXiPingCommand` | control | Ping / keepalive |
| `0x00F0` | `SXiDeviceIPAuthenticationCommand` | control | Authentication challenge response |
| `0x00F1` | `SXiDeviceAuthenticationCommand` | control | Device authentication |
| `0x0100` | `SXiAudioMuteCommand` | control | Mute/unmute |
| `0x0101` | `SXiAudioVolumeCommand` | control | Set volume |
| `0x0102` | `SXiAudioToneBassAndTrebleCommand` | control | Set bass/treble |
| `0x0104` | `SXiAudioEqualizerCommand` | control | Set EQ band gains |
| `0x0105` | `SXiAudioExciterCommand` | control | Exciter enable + gains |
| `0x0180` | `SXiAudioToneGenerateCommand` | control | Generate test tone |
| `0x0280` | `SXiSelectChannelCommand` | control | Tune/scan/flash/bulletin operations |
| `0x0282` | `SXiConfigureChannelAttributesCommand` | control | Configure channel attribute bits |
| `0x0283` | `SXiConfigureChannelSelectionCommand` | control | Configure selection/scan criteria |
| `0x0284` | `SXiListChannelAttributesCommand` | control | Set lists (presets, TuneMix) |
| `0x0304` | `SXiMonitorSeekCommand` | control | Smart-favorite “seek” monitors |
| `0x0402` | `SXiInstantReplayPlaybackControlCommand` | control | Instant Replay playback controls |
| `0x0500` | `SXiMonitorDataServiceCommand` | control | Start/stop monitoring DSIs (data plane) |
| `0x0EC0` | `SXiDebugActivateCommand` | control | Debug activation |
| `0x0ED0` | `SXiPackageCommand` | control | Query/select/report package |
| `0x0F00` | `SXiDebugResetCommand` | control | Debug reset |
| `0x0F03` | `SXiDebugWrite*Command` | control | Debug write (bytes/words/dwords) |
| `0x0F04` | `SXiDebugMonitorCommand` | control | Debug read/monitor memory |
| `0x0F05` | `SXiDebugUnmonitorCommand` | control | Stop debug monitor |
| `0x0F07` | `SXiDebugTunnelCommand` | control | Debug tunnel |
| `0x0F09` | `SXiDebugCommand` | control | Debug command (4 bytes) |

## Known indications (Device to Host)

Orbit recognizes the following indication opcodes (see `SXiPayload.indications` in [`lib/sxi_payload.dart`](../lib/sxi_payload.dart)):

| Opcode | Name (Orbit) | Typical payload type | Summary |
| --- | --- | --- | --- |
| `0x8020` | `SXiConfigureModuleIndication` | control | Device/module version + capability |
| `0x8021` | `SXiPowerModeIndication` | control | Power state changes |
| `0x8060` | `SXiTimeIndication` | control | Device time (minute/hour/day/month/year) |
| `0x8080` | `SXiEventIndication` | control | System events (info/errors/actions) |
| `0x80A0` | `SXiStatusIndication` | control | Status monitor item updates |
| `0x80C0` | `SXiDisplayAdvisoryIndication` | control | Channel advisory/warnings |
| `0x80C1` | `SXiSubscriptionStatusIndication` | control | Subscription / activation status |
| `0x8200` | `SXiBrowseChannelIndication` | control | Browse channel info (scan/browse results) |
| `0x8201` | `SXiCategoryInfoIndication` | control | Category list updates |
| `0x8280` | `SXiSelectChannelIndication` | control | “Tuned” channel confirmation + now playing |
| `0x8281` | `SXiChannelInfoIndication` | control | Channel list updates |
| `0x8300` | `SXiMetadataIndication` | control | Now playing metadata (strings + TMI block) |
| `0x8301` | `SXiChannelMetadataIndication` | control | Channel metadata (CMI block) |
| `0x8302` | `SXiGlobalMetadataIndication` | control | Global metadata (GMI block) |
| `0x8303` | `SXiLookAheadMetadataIndication` | control | Look‑ahead track metadata (TMI block) |
| `0x8304` | `SXiSeekIndication` | control | Favorites (“seek”) matches |
| `0x8402` | `SXiInstantReplayPlaybackInfoIndication` | control | Instant replay playback state/position |
| `0x8403` | `SXiInstantReplayPlaybackMetadataIndication` | control | IR now playing metadata |
| `0x8404` | `SXiInstantReplayRecordInfoIndication` | control | IR buffer usage + newest/oldest |
| `0x8405` | `SXiInstantReplayRecordMetadataIndication` | control | IR recorded track metadata |
| `0x8420` | `SXiBulletinStatusIndication` | control | Bulletin state |
| `0x8421` | `SXiFlashIndication` | control | Flash event info |
| `0x8422` | `SXiContentBufferedIndication` | control | Content buffered confirmation |
| `0x8442` | `SXiRecordTrackMetadataIndication` | control | Recorded track metadata |
| `0x8500` | `SXiDataServiceStatusIndication` | control | Data service availability + DMI list |
| `0x8510` | `SXiDataPacketIndication` | data | Data packets (often SDTP) |
| `0x80F0` | `SXiIPAuthenticationIndication` | control | Auth challenge |
| `0x80F1` | `SXiAuthenticationIndication` | control | Auth challenge response |
| `0x8E84` | `SXiFirmwareEraseIndication` | control | Firmware erase status |
| `0x8ED0` | `SXiPackageIndication` | control | Active subscription package information |
| `0xC26F` | `SXiErrorIndication` | control | Error payload (see `SXiError`) |

## Locations in code

- **Framing / checksum / resync**: [`lib/device_layer.dart`](../lib/device_layer.dart), [`lib/device_message.dart`](../lib/device_message.dart)
- **Opcode dispatch + indication handling**: [`lib/sxi_payload.dart`](../lib/sxi_payload.dart), [`lib/sxi_layer.dart`](../lib/sxi_layer.dart), [`lib/sxi_indications.dart`](../lib/sxi_indications.dart)
- **Command payloads**: [`lib/sxi_commands.dart`](../lib/sxi_commands.dart)
- **Metadata parsing**: [`lib/metadata/metadata.dart`](../lib/metadata/metadata.dart)

