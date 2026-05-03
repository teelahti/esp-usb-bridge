# ESP USB Bridge - Project Knowledge

## Overview

Fork of [espressif/esp-usb-bridge](https://github.com/espressif/esp-usb-bridge) customized for an **ESP32-S3 Super Mini** board. The firmware turns the ESP32-S3 into a USB composite device with:

- **CDC ACM** (`/dev/ttyACM0`) -- UART bridge to a target ESP board
- **Vendor** -- JTAG debug probe
- **MSC** -- UF2 mass storage for drag-and-drop flashing

## Hardware Setup

- **Bridge device:** ESP32-S3 Super Mini (soldered to protoboard)
- **Target device:** Lilygo T-ETH-Lite S3
- **Host OS:** NixOS with IDF v5.5.2 (via devenv + nixpkgs-esp-dev)

## Build

```bash
# devenv sets SDKCONFIG_DEFAULTS automatically:
# "sdkconfig.defaults.esp_prog2_s3_supermini;sdkconfig.defaults.esp32s3"
idf.py fullclean
idf.py build
idf.py -p /dev/ttyACM0 flash
```

The base `sdkconfig.defaults` is always included by ESP-IDF automatically.

## GPIO Pin Mapping (esp_prog2_s3_supermini)

### Serial (UART to target)
| Function | GPIO | Config Symbol |
|----------|------|---------------|
| TXD      | 4    | `CONFIG_SERIAL_HANDLER_GPIO_TXD` |
| RXD      | 5    | `CONFIG_SERIAL_HANDLER_GPIO_RXD` |
| RST      | 6    | `CONFIG_SERIAL_HANDLER_GPIO_RST` |
| BOOT     | 7    | `CONFIG_SERIAL_HANDLER_GPIO_BOOT` |

### Debug (JTAG)
| Function | GPIO | Config Symbol |
|----------|------|---------------|
| TDI      | 33   | `CONFIG_DEBUG_PROBE_GPIO_TDI` |
| TDO      | 21   | `CONFIG_DEBUG_PROBE_GPIO_TDO` |
| TCK      | 18   | `CONFIG_DEBUG_PROBE_GPIO_TCK` |
| TMS      | 17   | `CONFIG_DEBUG_PROBE_GPIO_TMS` |

### LEDs
| Function | GPIO | Active Level |
|----------|------|-------------|
| LED1 (TX) | 48  | Low (onboard S3 Super Mini LED) |
| LED2 (RX) | 34  | Low |
| LED3 (JTAG) | 34 | Low |

### Console UART (boot log)
- TX: GPIO43, RX: GPIO44 (ESP-IDF default, on bottom of board -- hard to access)

## Architecture & Data Flow

### USB CDC -> Target (Host writes to /dev/ttyACM0)
```
tud_cdc_rx_cb()                     [main/serial_bridge.c]
  -> serial_handler_send_data()     [components/serial_handler/serial_handler.c]
    -> uart_write_bytes(UART1)      -> GPIO4 (TXD) -> Target RXD
```

### Target -> USB CDC (Target sends UART data)
```
GPIO5 (RXD) <- Target TXD
  -> UART1 RX event in queue
  -> uart_event_task()              [components/serial_handler/serial_handler.c]
    -> data_callback()
      = transport_data_received_callback()  [main/serial_bridge.c]
        -> xRingbufferSend(usb_sendbuf)
  -> usb_sender_task()              [main/serial_bridge.c]
    -> tud_cdc_write() + flush      -> Host reads /dev/ttyACM0
```

### DTR/RTS -> BOOT/RST (esptool auto-reset)
```
tud_cdc_line_state_cb()             [main/serial_bridge.c]
  -> serial_handler_set_boot_reset_pins()
    -> gpio_set_level(GPIO_BOOT/GPIO_RST)
```

### MSC Flashing (UF2 drag-and-drop)
```
USB MSC write -> msc.c FAT16 handler
  -> serial_handler_flash_connect()   [sets is_flashing=true]
  -> serial_handler_flash_write()     [uses esp_loader_* API]
  -> serial_handler_flash_finish()    [sets is_flashing=false]
```

## Key Implementation Details

### UART Initialization
- Uses `loader_port_esp32_init()` from `espressif/esp-serial-flasher` (managed component, ^1.8)
- This sets up UART driver on UART1, configures BOOT/RST as GPIO outputs
- The UART event queue handle is passed back through `serial_conf.uart_queue`
- `ESP_ERROR_CHECK` wraps init in `app_main()` -- if UART init fails, chip aborts (no USB enumeration)

### is_flashing Guard
- `serial_handler.c:102`: UART RX data is **silently dropped** when `is_flashing == true`
- Set to `true` by `serial_handler_flash_connect()` (triggered by MSC UF2 write)
- Set to `false` by `serial_handler_flash_finish()`
- If MSC write triggers but never completes (e.g., OS auto-mount writes garbage), `is_flashing` could get stuck

### USB Descriptor Layout
| Interface | Number | Endpoint |
|-----------|--------|----------|
| CDC Notification | 0 | 0x81 (IN) |
| CDC Data | 1 | 0x02 (OUT), 0x82 (IN) |
| Vendor (JTAG) | 2 | 0x03 (OUT), 0x83 (IN) |
| MSC | 3 | 0x04 (OUT), 0x84 (IN) |

## Diagnostic Features (added for debugging)

### Magic Query: "EUB?"
Send the bytes `EUB?` to `/dev/ttyACM0` to get a diagnostic response directly over CDC:
```python
import serial
s = serial.Serial('/dev/ttyACM0', 115200, timeout=1)
s.write(b'EUB?')
print(s.read(256))
```
Response shows: `is_flashing`, GPIO pin assignments, current baudrate.

### Loopback Test
Jumper GPIO4 (TXD) to GPIO5 (RXD), then:
```python
import serial
s = serial.Serial('/dev/ttyACM0', 115200, timeout=1)
s.write(b'hello')
print(s.read(5))  # should print b'hello'
```

### Periodic Status Log
Every 10 seconds, `serial_handler` logs its state to the console UART (GPIO43/44):
```
[DIAG] is_flashing=0, callback=set, type=0, initialized=1
```

## sdkconfig.defaults Variants

| File | Purpose |
|------|---------|
| `sdkconfig.defaults` | Base (WDT disable, MD5 enable) |
| `sdkconfig.defaults.esp32s3` | Target chip (S3, 240MHz, cache sizes) |
| `sdkconfig.defaults.esp32s2` | Target chip (S2, 240MHz, cache sizes) |
| `sdkconfig.defaults.esp_prog2` | Original ESP-Prog-2 board pin layout |
| `sdkconfig.defaults.esp_prog2_s3_supermini` | **Our board** -- swapped serial/debug pins |
| `sdkconfig.jtag.defaults` | Debug interface: JTAG mode |
| `sdkconfig.swd.defaults` | Debug interface: SWD/CMSIS-DAP mode |

The `esp_prog2` and `esp_prog2_s3_supermini` variants have **serial and debug pin groups swapped** relative to each other.

## Target Wiring (Lilygo T-ETH-Lite S3)

| Bridge (S3 Super Mini) | Target (T-ETH-Lite S3) | Function |
|------------------------|------------------------|----------|
| GPIO4 (TXD)            | RXD (GPIO44)           | Serial data bridge->target |
| GPIO5 (RXD)            | TXD (GPIO43)           | Serial data target->bridge |
| GPIO6 (RST)            | EN                     | Reset control |
| GPIO7 (BOOT)           | GPIO0 (IO0)            | Download mode control |
| GND                    | GND                    | Common ground |

The T-ETH-Lite S3 has a physical BOOT button on GPIO0. GPIO0 is also available on the pin header (labeled `0` or `IO0`).

### Verified Working

- Serial passthrough: `picocom -b 115200 /dev/ttyACM0` shows target logs
- esptool auto-reset: `esptool --port /dev/ttyACM0 chip_id` connects and identifies ESP32-S3
- Loopback test: jumpering GPIO4<->GPIO5 echoes data back through CDC

## Dependencies

- ESP-IDF v5.0+ (currently using v5.5.2 via nixpkgs-esp-dev)
- `espressif/esp-serial-flasher` ^1.8 (managed component, fetched at build time)
- TinyUSB (bundled with ESP-IDF)
