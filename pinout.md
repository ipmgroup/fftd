# ICEZero (TE0876-03) Pinout

Извлечено из `pinout.xlsx` (Trenz Electronic, REV02).

## Краткая сводка интерфейсов

| Интерфейс | Разъём | Пины RPi GPIO | Пины FPGA | Назначение |
|-----------|--------|--------------|-----------|------------|
| **SPI0 (Mesa Bus)** | P11 | MOSI(10), MISO(9), SCK(11), CE0(8), CE1(7) | 90, 87, 79, 85, 78 | Данные + программирование |
| **CFG (конфигурация)** | P11 | GPIO5,6,12,13,16,26 | 65,68,71,67,70,66 | Загрузка bitstream |
| **I²C** | P11 | GPIO2,3 (SDA,SCL) | 115, 114 | ID EEPROM + расширение |
| **UART (отладка)** | P11 | GPIO14,15 (TXD,RXD) | 113, 112 | Консоль отладки |
| **GPIO** | P11 | GPIO22,24,25 | 101, 99, 88 | Управление/статус |
| **PMOD A** | P1 | — | 139,137,135,130,141,138,136,134 | GPIO общего назначения |
| **PMOD B** | P2 | — | 56,48,45,43,55,47,44,42 | GPIO общего назначения |
| **PMOD C** | P3 | — | 26,29,28,52,41,39,38,37 | GPIO общего назначения |
| **PMOD D** | P4 | — | 21,20,8,7,1,144,143,142 | GPIO общего назначения |
| **FTDI** | J3 | — | 119,122,124,125 | FTDI WO/WI/RO/RI |
| **XTRA** | J1 | — | 120,117,121,118,116 | Доп. GPIO |

---

## J1 — XTRA Header (6-pin)

| Pin | Net Name | FPGA Pin | Trace (mm) |
|-----|----------|----------|------------|
| 1 | XTRA_A_0 | 120 | 46.593 |
| 2 | XTRA_A_3 | 117 | 52.644 |
| 3 | XTRA_A_1 | 121 | 43.1869 |
| 4 | XTRA_A_4 | 118 | 49.7471 |
| 5 | XTRA_A_2 | 116 | 45.6985 |
| 6 | GND | — | — |

## J2 — Power (2-pin)

| Pin | Net Name | FPGA Pin | Trace (mm) |
|-----|----------|----------|------------|
| 1 | 5V | — | — |
| 2 | GND | — | — |

## J3 — FTDI Pin Header (6-pin)

| Pin | Net Name | FPGA Pin | Trace (mm) |
|-----|----------|----------|------------|
| 1 | GND | — | — |
| 2 | FTDI_WO | 119 | 13.3459 |
| 3 | 5V | — | — |
| 4 | FTDI_WI | 122 | 18.05 |
| 5 | FTDI_RO | 124 | 19.7796 |
| 6 | FTDI_RI | 125 | 20.3288 |

## P1 — PMOD A (12-pin GPIO)

| Pin | Net Name | FPGA Pin | Trace (mm) |
|-----|----------|----------|------------|
| 1 | GPIO_PIN_1 | 139 | 15.6104 |
| 2 | GPIO_PIN_3 | 137 | 15.0906 |
| 3 | GPIO_PIN_5 | 135 | 14.608 |
| 4 | GPIO_PIN_7 | 130 | 32.9998 |
| 5 | GND | — | — |
| 6 | 3.3V | — | — |
| 7 | GPIO_PIN_0 | 141 | 17.964 |
| 8 | GPIO_PIN_2 | 138 | 17.6513 |
| 9 | GPIO_PIN_4 | 136 | 19.1554 |
| 10 | GPIO_PIN_6 | 134 | 18.7606 |
| 11 | GND | — | — |
| 12 | 3.3V | — | — |

## P2 — PMOD B (12-pin GPIO)

| Pin | Net Name | FPGA Pin | Trace (mm) |
|-----|----------|----------|------------|
| 1 | GPIO_PIN_9 | 56 | 22.2916 |
| 2 | GPIO_PIN_11 | 48 | 23.4612 |
| 3 | GPIO_PIN_13 | 45 | 22.5691 |
| 4 | GPIO_PIN_15 | 43 | 21.8277 |
| 5 | GND | — | — |
| 6 | 3.3V | — | — |
| 7 | GPIO_PIN_8 | 55 | 25.0444 |
| 8 | GPIO_PIN_10 | 47 | 26.2437 |
| 9 | GPIO_PIN_12 | 44 | 25.2127 |
| 10 | GPIO_PIN_14 | 42 | 24.5748 |
| 11 | GND | — | — |
| 12 | 3.3V | — | — |

## P3 — PMOD C (12-pin GPIO)

| Pin | Net Name | FPGA Pin | Trace (mm) |
|-----|----------|----------|------------|
| 1 | GPIO_PIN_28 | 26 | 26.7322 |
| 2 | GPIO_PIN_29 | 29 | 18.9941 |
| 3 | GPIO_PIN_30 | 28 | 16.2501 |
| 4 | GPIO_PIN_31 | 52 | 16.6325 |
| 5 | GND | — | — |
| 6 | 3.3V | — | — |
| 7 | GPIO_PIN_16 | 41 | 12.8306 |
| 8 | GPIO_PIN_17 | 39 | 11.9092 |
| 9 | GPIO_PIN_18 | 38 | 13.1884 |
| 10 | GPIO_PIN_19 | 37 | 8.5135 |
| 11 | GND | — | — |
| 12 | 3.3V | — | — |

## P4 — PMOD D (12-pin GPIO)

| Pin | Net Name | FPGA Pin | Trace (mm) |
|-----|----------|----------|------------|
| 1 | GPIO_PIN_24 | 21 | 9.423 |
| 2 | GPIO_PIN_25 | 20 | 11.4338 |
| 3 | GPIO_PIN_26 | 8 | 8.1179 |
| 4 | GPIO_PIN_27 | 7 | 10.2229 |
| 5 | GND | — | — |
| 6 | 3.3V | — | — |
| 7 | GPIO_PIN_20 | 1 | 18.1362 |
| 8 | GPIO_PIN_21 | 144 | 15.8644 |
| 9 | GPIO_PIN_22 | 143 | 14.28 |
| 10 | GPIO_PIN_23 | 142 | 15.2211 |
| 11 | GND | — | — |
| 12 | 3.3V | — | — |

## P11 — Raspberry Pi HAT (40-pin GPIO)

| Pin | Net Name | FPGA Pin | Trace (mm) |
|-----|----------|----------|------------|
| 1 | NetP11_1 | -- | #N/A |
| 2 | 5V | — | — |
| 3 | PI_I2C_SDA | 115 | 14.8252 |
| 4 | 5V | — | — |
| 5 | PI_I2C_SCL | 114 | 8.0007 |
| 6 | GND | — | — |
| 7 | NetP11_7 | -- | #N/A |
| 8 | PI_UART_WI | 113 | 12.3802 |
| 9 | GND | — | — |
| 10 | PI_UART_RO | 112 | 7.4561 |
| 11 | NetP11_11 | -- | #N/A |
| 12 | NetP11_12 | -- | #N/A |
| 13 | NetP11_13 | -- | #N/A |
| 14 | GND | — | — |
| 15 | PI_GPIO_2 | 101 | 9.0316 |
| 16 | NetP11_16 | -- | #N/A |
| 17 | NetP11_17 | -- | #N/A |
| 18 | PI_GPIO_1 | 99 | 10.6723 |
| 19 | PI_SPI_MOSI | 90 | 12.705 |
| 20 | GND | — | — |
| 21 | PI_SPI_MISO | 87 | 12.307 |
| 22 | PI_GPIO_0 | 88 | 9.4991 |
| 23 | PI_SPI_SCK | 79 | 8.7431 |
| 24 | PI_SPI_CE_0 | 85 | 10.5449 |
| 25 | GND | — | — |
| 26 | PI_SPI_CE_1 | 78 | 8.069 |
| 27 | PI_ID_0 | 73 | 10.6385 |
| 28 | PI_ID_1 | 74 | 7.4966 |
| 29 | CFG_DONE | 65 | 8.7003 |
| 30 | GND | — | — |
| 31 | CFG_SI | 68 | 13.2773 |
| 32 | CFG_SS | 71 | 18.2027 |
| 33 | CFG_SO | 67 | 13.707 |
| 34 | GND | — | — |
| 35 | NetP11_35 | -- | #N/A |
| 36 | CFG_SCK | 70 | 19.7829 |
| 37 | CFG_RST_1 | 66 | 21.5451 |
| 38 | NetP11_38 | -- | #N/A |
| 39 | GND | — | — |
| 40 | NetP11_40 | -- | #N/A |

### Raspberry Pi GPIO Mapping

| P11 Pin | RPi Signal | FPGA Net |
|---------|-----------|----------|
| 1 | 3.3V | NetP11_1 |
| 2 | 5V | 5V |
| 3 | GPIO2 (SDA1) | PI_I2C_SDA |
| 4 | 5V | 5V |
| 5 | GPIO3 (SCL1) | PI_I2C_SCL |
| 6 | GND | GND |
| 7 | GPIO4 | NetP11_7 |
| 8 | GPIO14 (TXD) | PI_UART_WI |
| 9 | GND | GND |
| 10 | GPIO15 (RXD) | PI_UART_RO |
| 11 | GPIO17 | NetP11_11 |
| 12 | GPIO18 (PCM_CLK) | NetP11_12 |
| 13 | GPIO27 | NetP11_13 |
| 14 | GND | GND |
| 15 | GPIO22 | PI_GPIO_2 |
| 16 | GPIO23 | NetP11_16 |
| 17 | 3.3V | NetP11_17 |
| 18 | GPIO24 | PI_GPIO_1 |
| 19 | GPIO10 (MOSI) | PI_SPI_MOSI |
| 20 | GND | GND |
| 21 | GPIO9 (MISO) | PI_SPI_MISO |
| 22 | GPIO25 | PI_GPIO_0 |
| 23 | GPIO11 (SCLK) | PI_SPI_SCK |
| 24 | GPIO8 (CE0) | PI_SPI_CE_0 |
| 25 | GND | GND |
| 26 | GPIO7 (CE1) | PI_SPI_CE_1 |
| 27 | ID_SD (I2C EEPROM) | PI_ID_0 |
| 28 | ID_SC (I2C EEPROM) | PI_ID_1 |
| 29 | GPIO5 | CFG_DONE |
| 30 | GND | GND |
| 31 | GPIO6 | CFG_SI |
| 32 | GPIO12 | CFG_SS |
| 33 | GPIO13 | CFG_SO |
| 34 | GND | GND |
| 35 | GPIO19 (SPI1 MISO) | NetP11_35 |
| 36 | GPIO16 | CFG_SCK |
| 37 | GPIO26 | CFG_RST_1 |
| 38 | GPIO20 (SPI1 MOSI) | NetP11_38 |
| 39 | GND | GND |
| 40 | GPIO21 (SPI1 SCLK) | NetP11_40 |
