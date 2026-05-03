# ESP USB Bridge Debug Report

## Goal

Use an ESP32-S3 Super Mini flashed with [esp-usb-bridge](https://github.com/espressif/esp-usb-bridge) as a USB-to-UART bridge for:
1. Flashing firmware to a target ESP32 board (Lilygo T-ETH-Lite S3) via ESPHome/esptool
2. Reading UART logs from the target for debugging

## Hardware

- **Bridge device:** ESP32-S3 Super Mini
- **Target device:** Lilygo T-ETH-Lite S3
- **Host OS:** NixOS with SwayWM, IDF v5.5.2 (Nix-wrapped)

## Current Status

The bridge firmware is flashed and the USB device enumerates correctly. However, no data flows through the UART bridge — esptool cannot connect to the target via `/dev/ttyACM0`, and UART logs are not received.

## What Works

- USB enumeration is fully correct. All 4 interfaces appear as expected:
  - `/dev/ttyACM0` — CDC ACM serial (interface 0/1)
  - JTAG — vendor-specific (interface 2)
  - Mass storage UF2 disk — (interface 3, shows as `/dev/sda`)
- The bridge firmware builds and flashes successfully via `idf.py`
- A minimal IDF UART loopback test app confirms that GPIO4/5 and GPIO8/9 are both functional for UART on this board
- The `sdkconfig` after build correctly reflects the configured GPIO pin numbers

## What Doesn't Work

- Loopback test via `/dev/ttyACM0` while bridge firmware is running returns `b''`
- `esptool --port /dev/ttyACM0 --no-stub --before no-reset --after no-reset chip-id` times out with "No serial data received"
- UART logs from target are not received

## Build Configuration

The firmware was built with:

```bash
export SDKCONFIG_DEFAULTS="sdkconfig.defaults.esp32s3;sdkconfig.defaults.esp_prog2"
rm sdkconfig
idf.py fullclean
idf.py build
idf.py -p /dev/ttyACM0 flash
```

Verified that the resulting `sdkconfig` contains the correct GPIO values:

```
CONFIG_SERIAL_HANDLER_GPIO_BOOT=7
CONFIG_SERIAL_HANDLER_GPIO_RST=6
CONFIG_SERIAL_HANDLER_GPIO_RXD=5
CONFIG_SERIAL_HANDLER_GPIO_TXD=4
```

These map to physical pins IO4, IO5, IO6, IO7 on the Super Mini board, which are confirmed safe and functional GPIOs.

## Key Code Path

The UART is initialized in `components/serial_handler/serial_handler.c` via `loader_port_esp32_init()`:

```c
const loader_esp32_config_t serial_conf = {
    .baud_rate = SLAVE_UART_DEFAULT_BAUD,  // 115200
    .uart_port = SLAVE_UART_NUM,           // UART_NUM_1
    .uart_rx_pin = GPIO_RXD,
    .uart_tx_pin = GPIO_TXD,
    .rx_buffer_size = SLAVE_UART_BUF_SIZE * 2,
    .tx_buffer_size = 0,
    .uart_queue = &s_transport.uart_queue,
    .queue_size = 20,
    .reset_trigger_pin = GPIO_RST,
    .gpio0_trigger_pin = GPIO_BOOT,
};
```

## Reset/Boot Pin Wiring

- GPIO6 (RST) was previously wired to target EN — currently disconnected
- GPIO7 (BOOT) has never been wired — no accessible BOOT/GPIO0 pin found on Lilygo T-ETH-Lite S3
- Target was put into download mode manually for flash attempts (held BOOT button, pressed RST)
- Even with manual boot mode and `--before no-reset`, esptool cannot connect

## Most Likely Remaining Issue

The bridge firmware's boot log (via `loader_port_esp32_init` success/failure) has not been captured yet. The S3 Super Mini console UART is on GPIO43 (TX) and GPIO44 (RX) — reading these with a separate USB-TTL adapter while the bridge firmware runs would show whether the UART initializes successfully or silently fails.

## Suggested Next Steps for Claude Code

1. **Capture bridge firmware boot log** by connecting a USB-TTL adapter to GPIO43/44 of the Super Mini at 115200 baud while the bridge firmware is running. Look for `loader_port_esp32_init failed` or `UART have been initialized` in the output.

2. **Add explicit logging to the bridge firmware** around `loader_port_esp32_init()` and the CDC-to-UART data path to confirm data is being received from the host and forwarded to the UART peripheral.

3. **Check the CDC data path** — trace how data arriving on `ttyACM0` from the host gets routed to `serial_handler_send_data()`. Verify that the USB CDC receive callback is actually triggering when data arrives.

4. **Check `sdkconfig.defaults.esp_prog2`** for `CONFIG_BRIDGE_UART_TX_GPIO` / `CONFIG_BRIDGE_UART_RX_GPIO` — these symbols do not appear in any Kconfig file and may be silently ignored. The active symbols are `CONFIG_SERIAL_HANDLER_GPIO_TXD` and `CONFIG_SERIAL_HANDLER_GPIO_RXD`.

5. **Find GPIO0 on Lilygo T-ETH-Lite S3** — check the [LilyGO T-ETH-Series schematic](https://github.com/Xinyuan-LilyGO/LilyGO-T-ETH-Series) for whether GPIO0 is accessible as a test pad. Without BOOT pin control, auto-reset during flashing will not work even when the bridge UART is functional.
