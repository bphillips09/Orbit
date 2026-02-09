# Orbit

<img src="https://i.imgur.com/ujr1TKY.png" alt="Orbit on macOS (Landscape)" height="250" /> <img src="https://i.imgur.com/8LgfafM.png" alt="Orbit on Web (Portrait)" height="250" />

> _Screenshots of Orbit on macOS and Web_

An offline satellite radio player that can work completely without internet.

Orbit connects to an [SXV300][sxv300-link] tuner and controls it using the SXi protocol.

## Features

| Feature | Status |
| --- | --- |
| Play / Pause / Fast‑Forward / Rewind | ✅ Supported |
| Channel Forward / Back / Tune |  ✅ Supported |
| Song / Artist / Channel information | ✅ Supported |
| Album artwork (downloaded from satellite) | ✅ Supported |
| Channel logos (downloaded from satellite) | ✅ Supported |
| Channel info (description, similar channels) | ✅ Supported |
| Now‑playing guide | ✅ Supported |
| Presets | ✅ Supported |
| Presets Playback (up to an hour) | ✅ Supported |
| Presets Scan | ✅ Supported |
| Presets Mix | ✅ Supported |
| Restart song on tune | ✅ Supported |
| Song / Artist alerts | ✅ Supported |
| Internet Streaming | ⏳ In Progress |
| Weather / Data (downloaded from satellite) | ⏳ In Progress |
| Sports alerts | ⏳ Planned |

## Platforms

- [Android][releases-link]
- [macOS][releases-link]
- [Windows][releases-link]
- [Web][web-link] (Desktop, Chromium-based browsers)

## Getting started

1. See the [Hardware Setup](docs/hardware-setup.md) page to connect your device.
2. Download the [latest release][releases-link] for your platform or [Web][web-link]
2. Launch Orbit and choose the serial device when prompted.
3. Optionally select your audio input setup.
3. Start listening (applicable subscription needed). No internet connection required.

## Permissions

This app interacts with serial devices and can capture audio for playback. It requests permissions when needed:

- Android
  - <b>USB serial</b> (native)
  - <b>Microphone / Audio input</b>
- Desktop
  - <b>Serial API</b> (native)
  - <b>Microphone / Audio input</b>
- Web
  - <b>Serial API</b> (WebSerial)
  - <b>Microphone / Audio input</b>

## Building from Source

1. **Install Flutter**: [Flutter installation guide](https://docs.flutter.dev/get-started/install)
2. **Clone this repo:**
   ```sh
   git clone https://github.com/bphillips09/Orbit.git
   cd orbit
   ```
3. **Build or run the app:**
   ```sh
   flutter build [platform]
   #or 
   flutter run [platform]
   ```

## SXi Documentation
- [Reverse-Engineered SXi protocol](docs/sxi-protocol.md)

## Disclaimer

This project is unaffiliated with any satellite radio provider. Names and trademarks belong to their respective owners.

[sxv300-link]: <https://amazon.com/dp/B00NJTO4CY>
[releases-link]: <https://github.com/bphillips09/orbit/releases/latest>
[web-link]: <https://bphillips09.github.io/Orbit/>
