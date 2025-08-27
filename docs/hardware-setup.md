### Hardware Setup (SXV300)

This guide shows how to wire the SXV300 to a USB UART, audio input, and power. The diagram below summarizes all connections.


- The SXV300 uses a proprietary 10‑pin mini‑DIN connector (male). Only 8 pins are used.
- A ready‑made female connector pigtail is available from Dynavin if you don't want to solder.
- If you prefer direct wiring: the SXV300’s built‑in cable terminates at easily‑solderable test pads inside the case. The case opens with three Torx screws and gentle unsnapping along the corners.

## Pinout:

<div align="left">
  <table>
    <tr>
      <td align="center" style="border: none;">
        <img src="https://i.imgur.com/jQcuE5E.png" width="200" height="200" alt="Male pinout (SXV300)" />
        <div>Male (SXV300)</div>
      </td>
      <td align="center" style="border: none;">
        <img src="https://i.imgur.com/JUV0chn.png" width="200" height="200" alt="Female pinout" />
        <div>Female (radio)</div>
      </td>
    </tr>
  </table>
</div>

| Pin | SXV300 | Dynavin Cable | UART Adapter |
| --- | --- | --- | --- |
| 1 | GND $\color{green}{\blacksquare}$ | GND $\color{blue}{\blacksquare}$ | GND |
| 2 | 12V $\color{red}{\blacksquare}$ | 12V $\color{yellow}{\blacksquare}$ |  |
| 3 | Power Enable $\color{blue}{\blacksquare}$ | Power Enable $\color{orange}{\blacksquare}$ |  |
| 4 | Audio R $\color{purple}{\blacksquare}$ | Audio R $\color{red}{\blacksquare}$ |  |
| 5 | Audio GND $\color{black}{\blacksquare}$ | Audio GND $\color{black}{\blacksquare}$ |  |
| 6 | Tuner RX $\color{yellow}{\blacksquare}$ | Tuner RX $\color{brown}{\blacksquare}$ | <-- TX |
| 7 | Audio L $\color{white}{\blacksquare}$ | Audio L $\color{green}{\blacksquare}$ |  |
| 8 | Tuner TX $\color{orange}{\blacksquare}$ | Tuner TX $\color{white}{\blacksquare}$ | --> RX |



## Hardware Overview
<div align="left">
  <img src="https://i.imgur.com/9C9W2xL.png" alt="Hardware Overview" width="500" />
</div>

Wiring tips:
- UART TX connects to device RX; UART RX connects to device TX.
- UART GND connects to device GND.
- Audio L/R to your audio input’s L/R; Audio GND to audio ground/shield as appropriate.
- Power Enable can be tied to +12V (or a head unit “amp/ACC” enable) to turn the tuner on.
- Vehicle use: connect +12V to the battery or switched ACC with an inline fuse.
- Non‑vehicle use: a 12V 1A DC power adapter is recommended.
- The SXV300 cable terminates at solderable test pads inside the case, which opens with three Torx screws and gentle unsnapping at corners.

## Wiring Diagram
<div align="left">
  <a href="https://app.cirkitdesigner.com/project/0c22d9b6-d721-4c25-b506-b9e4cf0f9c46" target="_blank" rel="noopener noreferrer">
    <img src="https://i.imgur.com/4T3MgIE.jpeg" alt="Wiring Diagram" width="500" />
  </a>
</div>

## Connection Diagram (ASCII)
```text
Host (Android / macOS / Windows / Web)
  |- USB -> USB UART Adapter
  |- USB -> USB Audio Input

Power
  Battery 12V --(fuse)--> 12V rail
  or
  12V DC Adapter (1A) ----> 12V rail

SXV300 Tuner
  Pin 1: GND   <------ Common ground (UART GND, Audio GND)
  Pin 2: 12V   <------ 12V rail (fused)
  Pin 3: PwrEn <------ 12V rail or ACC/AMP enable
  Pin 4: Audio R ----> Audio Right
  Pin 5: Audio GND --> USB Audio Ground/Shield
  Pin 6: Tuner RX <--- Serial TX (TX -> Device RX)
  Pin 7: Audio L ----> Audio Left
  Pin 8: Tuner TX ---> Serial RX (Device TX -> RX)

Optional Dynavin female cable
  12V -> 12V rail (fused)
  GND -> Common ground
  Power Enable -> 12V or ACC/AMP enable
```

## Known-Working Adapters for All Platforms
- [USB UART](https://www.amazon.com/dp/B09F6FGMD7)
- [USB Audio-in](https://www.amazon.com/dp/B00NMXY2MO)
- [12V 1A DC Power Supply](https://www.amazon.com/dp/B0BX5F3562)
- [12V Cigarette Lighter Adapters](https://www.amazon.com/dp/B0CNJQC7T3)
- [Analog Audio Breakout Cable](https://www.amazon.com/dp/B0CQXSR3MV)
- [Dynavin Adapter Cable](https://dynavinnorthamerica.com/products/siriusxm-adapter-cable-for-the-dynavin-n7-only)
- [Dual USB Hub](https://www.amazon.com/dp/B098L7WJ4C)