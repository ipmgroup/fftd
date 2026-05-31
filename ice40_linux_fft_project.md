# Техническое задание

## FPGA DSP система с FFT ускорителем на базе ICE40HX4K для Linux

**Версия**: 1.0  
**Дата**: 2026-05-30  

---

## Термины, определения и сокращения

| Термин | Определение |
|--------|------------|
| **AXI Lite** | Облегчённый поднабор протокола AMBA AXI4 для memory-mapped соединений «ведущий-ведомый» |
| **BRAM** | Block RAM — встроенная блочная память FPGA |
| **DFT** | Discrete Fourier Transform — дискретное преобразование Фурье |
| **DSP** | Digital Signal Processing — цифровая обработка сигналов |
| **FFT** | Fast Fourier Transform — быстрое преобразование Фурье |
| **FIFO** | First In, First Out — аппаратная очередь |
| **FPGA** | Field-Programmable Gate Array — программируемая логическая интегральная схема |
| **FTE** | Full-Time Equivalent — эквивалент полной занятости |
| **HAT** | Hardware Attached on Top — плата расширения для Raspberry Pi |
| **LUT** | Look-Up Table — таблица поиска, базовый логический элемент FPGA |
| **MTBF** | Mean Time Between Failures — средняя наработка на отказ |
| **PIO** | Programmed Input/Output — программный ввод-вывод |
| **PMOD** | Стандарт периферийных модулей Digilent (6-контактный разъём) |
| **RTL** | Register Transfer Level — уровень описания цифровой схемы |
| **SDFT** | Sliding Discrete Fourier Transform — скользящее ДПФ |
| **UIO** | Userspace I/O — фреймворк Linux для драйверов в пользовательском пространстве |

---

## 1. Общие положения

### 1.1 Назначение проекта

Разработка встроенной системы обработки цифровых сигналов на базе FPGA ICE40HX4K с поддержкой аппаратного ускорения FFT и интеграцией в Linux окружение через драйвер ядра и user-space библиотеку.

### 1.2 Целевая платформа

**Аппаратное обеспечение:**
- **Плата**: Trenz Electronic ICEZero (TE0876-03-A)
- **FPGA**: Lattice ICE40HX4K-TQ144 (3520 LUT4, 80 kbits Block RAM, 40 nm)
- **Память**: 
  - 4 Mbit external SRAM (IS61WV25616BLL-10TLI, 256K×16, 10 ns, 512 kBytes)
  - 8 MByte QSPI Flash (для bitstream)
  - 2 kbit EEPROM
- **GPIO**: 
  - 32 x I/O (4 x PMOD разъёма, 6 pin каждый)
  - 4 x GPIO (FTDI Pin Header)
  - 5 x GPIO (Pin Header)
- **On-Board компоненты**:
  - Push Button (user input)
  - 3 x user LEDs (status/debug)
  - 100 MHz oscillator (clock source)
- **Питание**: 5V от Raspberry Pi (через 2x20 HAT коннектор)
- **Размер**: 30.5 x 65 mm (Raspberry Pi HAT compatible)
- **Интерфейсы**: Raspberry Pi standard GPIO header, PMOD-compatible connectors

**ПО и инструментарий:**
- **Toolchain**: Project IceStorm (fully open source)
  - Yosys (синтез)
  - nextpnr (place & route)
  - icepack (генерация bitstream)
  - iceprog (программирование)
- **ОС**: Linux (kernel 5.10+, arm64 на Raspberry Pi, x86_64 для разработки)
- **Язык**: Verilog (для RTL)

### 1.3 Область применения

Обработка сигналов в реальном времени, спектральный анализ, прототипирование DSP алгоритмов, образовательные проекты.

### 1.4 Рабочий процесс разработки

**Development Machine**: Linux (x86_64)
- Синтез и симуляция HDL (Yosys, iverilog, Verilator)
- Cross-compilation C/Python для ARM (gcc-arm-linux-gnueabihf)
- Build kernel driver и user-space lib
- Unit тесты и integration тесты (в т.ч. через mock FPGA)

**Target Hardware**: Raspberry Pi + ICEZero
- SSH доступ для remote development
- `scp` для загрузки bitstream и бинарников
- `ssh` для выполнения тестов и отладки
- `sshfs` опционально для remote mounting

**Workflow**:
```
┌─────────────────────────────────────────┐
│  Development Linux PC (x86_64)          │
├─────────────────────────────────────────┤
│ • Editing (VSCode, vim, etc.)          │
│ • Synthesis (Yosys, nextpnr)           │
│ • Simulation (iverilog, Verilator)     │
│ • Build (gcc for ARM, cross-compile)   │
│ • Unit tests (pytest, gtest)           │
│ • Generate bitstream (.bin)            │
│ • Cross-compile kernel driver          │
│ • Cross-compile user-space lib/apps    │
└──────────┬──────────────────────────────┘
           │ scp/ssh (over network)
           │
┌──────────▼──────────────────────────────┐
│  Raspberry Pi 4/5 + ICEZero             │
├─────────────────────────────────────────┤
│ • Load bitstream (iceprog)              │
│ • Load kernel driver (insmod)           │
│ • Run integration tests                 │
│ • Profile performance                   │
│ • Debug via serial/SSH                  │
└─────────────────────────────────────────┘
```

---

## 2. Требования

### 2.1 Функциональные требования

#### 2.1.1 FPGA компонента

| Требование | Спецификация |
|-----------|-------------|
| **FFT размер** | 32-точечная, 64-точечная, 128-точечная FFT (настраивается) |
| **Алгоритм** | Cooley-Tukey, DFT pipelined или Sliding DFT |
| **Разрядность данных** | 12-16 бит входные, 16-20 бит выходные |
| **Пропускная способность** | 1–10 MSPS в зависимости от размера FFT |
| **Интерфейсы** | AXI Lite / native memory-mapped I/O |
| **Дополнительно** | Оконная функция (Hann), масштабирование выходных данных |

#### 2.1.2 Периферия FPGA

- **UART**: 115200 bps для отладки через PMOD-разъём (опционально: через FTDI Pin Header — 4 GPIO пина на плате)
- **SPI Slave**: 32 МГц, протокол Mesa Bus для связи с Raspberry Pi
- **GPIO**: 8+ выводов (на PMOD разъёмах) для светодиодов, кнопок, PWM
- **I2C**: Опционально через PMOD (2 пина для SDA/SCL)

#### 2.1.3 Linux компонента

| Компонент | Требование |
|-----------|-----------|
| **Драйвер ядра** | UIO-based или misc device driver |
| **User-space library** | C/Python API, FFTW-совместимый интерфейс |
| **Утилиты** | `fft_load`, `fft_test`, `fft_profile` |
| **Документация** | API docs, примеры кода, README |

#### 2.1.4 Интеграция

- Загрузка bitstream через SPI с Raspberry Pi (`iceprog`)
- Доступ к FFT-регистрам через SPI (Mesa Bus Protocol, 32 МГц)
- Передача данных: PIO через SPI (DMA не поддерживается ICE40HX)
- Интерпретация результатов на Raspberry Pi (Python/C)

### 2.2 Нефункциональные требования

#### 2.2.1 Производительность

- **Латентность FFT**: < 100 мкс для 64-точечной FFT
- **Гарантированный такт**: 50 МГц (ICE40HX тип скорости 5)
- **Пиковая мощность**: < 500 мВт

#### 2.2.2 Надёжность и отладка

- Formal verification для критичных модулей (butterfly, twiddle ROM)
- Симуляция всех компонентов (iverilog/verilator)
- Testbench с проверкой против NumPy FFT
- Обработка ошибок и переполнения

#### 2.2.3 Масштабируемость

- Параметризация размера FFT (16, 32, 64, 128 точек)
- Поддержка different bitwidth configurations
- Возможность расширения в будущем (SDFT, real FFT)

#### 2.2.4 Совместимость

- Open source toolchain (Project IceStorm)
- Verilog/VHDL + Python для генерации
- Linux kernel 5.10+
- Поддержка GCC, GDB для отладки

### 2.3 Требования к электропитанию

| Параметр | Значение | Примечание |
|----------|----------|------------|
| Входное напряжение | 5.0 В ± 5% | От Raspberry Pi через HAT-коннектор |
| Пиковый ток | ≤ 150 мА | Суммарно FPGA + SRAM + периферия |
| Пиковая мощность | ≤ 500 мВт | Без учёта питания Raspberry Pi |
| Защита по току | Предохранитель 500 мА (на плате ICEZero) |
| Пусковой ток | ≤ 300 мА в течение ≤ 10 мс |
| Помехи по питанию | ≤ 50 мВ (peak-to-peak) на линии 5V |
| Резервное питание | Опционально: внешний 5V через Micro-USB |

### 2.4 Требования к условиям эксплуатации

| Параметр | Диапазон | Примечание |
|----------|----------|------------|
| Температура окружающей среды (рабочая) | 0…+70 °C | Коммерческий диапазон ICE40HX |
| Температура хранения | −40…+100 °C | |
| Относительная влажность (рабочая) | 10…90 % | Без конденсации |
| Атмосферное давление | 84…107 кПа | |
| Защита от ESD | ±2 кВ (HBM) | Стандарт JESD22-A114 |
| Вибрация | Не нормируется (лабораторное применение) | |

### 2.5 Требования к надёжности

| Параметр | Значение |
|----------|----------|
| Средняя наработка на отказ (MTBF) | ≥ 50 000 часов (расчётная) |
| Срок службы | ≥ 5 лет |
| Количество циклов перезаписи QSPI Flash | ≥ 100 000 |
| Допустимое количество перезагрузок FPGA | ≥ 10 000 |
| Время восстановления после сбоя | ≤ 5 секунд (перезагрузка драйвера + перепрограммирование) |
| Самодиагностика | Встроенный тест FIFO и контрольных регистров при инициализации |

### 2.6 Требования к патентной чистоте

- Все используемые программные компоненты распространяются под открытыми лицензиями (MIT, BSD, GPLv2, Apache 2.0)
- RTL-код FFT-ускорителя является оригинальной разработкой либо использует блоки с подтверждённой открытой лицензией
- Не используются проприетарные IP-ядра, требующие лицензионных отчислений
- Project IceStorm (Yosys, nextpnr, icepack) распространяется под лицензией ISC (permissive)

---

## 3. Архитектура системы

### 3.1 Структурная схема

```
┌─────────────────────────────────────────┐
│      Raspberry Pi + ICEZero (HAT)       │
├─────────────────────────────────────────┤
│  User-space App (Python/C)              │
│  └─ libfft.so (FFTW-compatible API)    │
├─────────────────────────────────────────┤
│  Linux Kernel                           │
│  └─ fft_driver.ko (UIO/misc driver)    │
│       └─ SPI subsystem (spidev)         │
├─────────────────────────────────────────┤
│   2x20 GPIO HAT Connector               │
│   ├─ SPI0 (MOSI,MISO,SCLK,CE0) 32 MHz  │
│   ├─ 5V power                           │
│   └─ GPIO control/status                │
└──────────┬──────────────────────────────┘
           │ SPI (Mesa Bus Protocol)
           │
┌──────────▼──────────────────────────────┐
│     ICEZero Board (ICE40HX4K)           │
├──────────────────────────────────────────┤
│  ┌──────────────────────────────────┐   │
│  │  FFT Accelerator Module          │   │
│  │  ┌─────────────────────────────┐ │   │
│  │  │ AXI Lite Slave Interface    │ │   │
│  │  └──────┬──────────────────────┘ │   │
│  │         │                        │   │
│  │  ┌──────▼──────────────────────┐ │   │
│  │  │ Control Registers (16 regs) │ │   │
│  │  │ Status, Config, IRQ masks   │ │   │
│  │  └──────────────────────────────┘ │   │
│  │         │                        │   │
│  │  ┌──────▼──────────────────────┐ │   │
│  │  │ Input Data FIFO (256 bytes) │ │   │
│  │  └──────────────────────────────┘ │   │
│  │         │                        │   │
│  │  ┌──────▼──────────────────────┐ │   │
│  │  │ FFT Engine (pipelined)      │ │   │
│  │  │ • Butterfly stages          │ │   │
│  │  │ • Twiddle ROM (parameterized)   │   │
│  │  │ • Bit-reverser              │ │   │
│  │  │ • Scaling/Windowing         │ │   │
│  │  └──────────────────────────────┘ │   │
│  │         │                        │   │
│  │  ┌──────▼──────────────────────┐ │   │
│  │  │ Output Data FIFO (256 bytes) │ │   │
│  │  └──────────────────────────────┘ │   │
│  └──────────────────────────────────┘   │
│                                          │
│  ┌──────────────────────────────────┐   │
│  │ SPI Slave (Mesa Bus, 32 MHz)     │   │
│  │ ├─ Register access (read/write)  │   │
│  │ ├─ Bitstream loading             │   │
│  │ └─ DMA/PIO data transfer         │   │
│  └──────────────────────────────────┘   │
│                                          │
│  ┌──────────────────────────────────┐   │
│  │ Peripheral Bus (memory-mapped)   │   │
│  │ ├─ UART Controller (PMOD)        │   │
│  │ ├─ GPIO Controller (8 pins)      │   │
│  │ └─ SRAM Controller (4 Mbit)      │   │
│  └──────────────────────────────────┘   │
└──────────────────────────────────────────┘
```

### 3.2 Компоненты FPGA

| Модуль | Назначение | LUT | BRAM | Примечания |
|--------|-----------|-----|------|-----------|
| `fft_engine` | Основной FFT ускоритель | 1000–1200 | 40 | Generator-based, opt. для HX4K |
| `axi_lite_slave` | AXI Lite интерфейс | 120 | 0 | Контролер, статус |
| `fifo_input` | Входной буфер | 60 | 4 | 256 bytes (вместо 512) |
| `fifo_output` | Выходной буфер | 60 | 4 | 256 bytes |
| `uart_ctrl` | UART контролер | 100 | 0 | 115200 bps (опциональный) |
| `gpio_ctrl` | GPIO контролер | 60 | 0 | 8 выводов |
| `sram_controller` | SRAM controller | 150 | 0 | 4M SRAM доступна |
| **Всего (max)** | | **1800–2000** | **80** | **~50–57% LUT** |

### 3.3 Linux компоненты

```
Host System
├── User Application
│   └── libfft (C/Python bindings)
│       ├── fft_init()
│       ├── fft_compute_forward()
│       ├── fft_compute_inverse()
│       └── fft_get_config()
│
├── Kernel Driver (fft_driver.ko)
│   ├── UIO device registration (/dev/fft_0)
│   ├── Memory-mapped register access
│   ├── Interrupt handling
│   └── DMA setup (если поддерживается)
│
└── Bitstream Management
    ├── iceprog (SPI programming via Raspberry Pi GPIO)
    └── QSPI Flash bootloader (optional)
```

---

## 4. Этапы разработки

### Этап 1: Подготовка окружения (Неделя 1–2)

**Задачи:**
- Установка Project IceStorm toolchain (Yosys, nextpnr, icepack)
- Подготовка ICEZero платы (установка на HAT-коннектор Raspberry Pi)
- Создание базового Makefile для сборки
- Тестирование загрузки простой Verilog программы (LED blink)

**Выходные данные:**
- Скрипты сборки
- Документация по настройке окружения
- Тестовый bitstream для проверки платы

**Критерии завершения:**
- LED on ICEZero мигает с частотой 1 Hz

---

### Этап 2: Разработка FFT ядра (Неделя 3–6)

**Задачи:**
- Выбор и адаптация FFT генератора (dblclockfft или Sliding DFT)
- Параметризация под ICE40HX4K (32/64-точечная FFT)
- Написание testbench (Verilog/Python)
- Formal verification butterfly модуля
- RTL симуляция против NumPy FFT

**Выходные данные:**
- `fft_core.v` (сгенерированный Verilog)
- `fft_tb.v` (testbench)
- `verify_fft.py` (Python скрипт проверки)
- `fft_spec.md` (спецификация)

**Критерии завершения:**
- Все тесты проходят
- Ошибка < 1 LSB относительно NumPy на 100 случайных векторов

---

### Этап 3: Интеграция периферии (Неделя 7–10)

**Задачи:**
- Разработка AXI Lite slave интерфейса
- Реализация FIFO (input/output)
- UART контролер для отладки
- Модульное тестирование каждого компонента

**Выходные данные:**
- `axi_lite_slave.v`
- `fifo_512.v`
- `uart_115200.v`
- `top_design.v` (интеграция всех модулей)

**Критерии завершения:**
- Синтез top-уровня без ошибок
- Place & Route успешный
- Резидентное потребление < 80% LUT

---

### Этап 4: Разработка Linux драйвера (Неделя 11–13)

**Задачи:**
- Написание UIO-based driver kernel module
- Device node создание (`/dev/fft_0`)
- Interrupt handling (опционально)
- Implement ioctl для управления

**Выходные данные:**
- `fft_driver.c` (kernel module)
- `fft_driver.h` (API)
- Makefile для компиляции модуля
- `README_driver.md` (документация)

**Критерии завершения:**
- `insmod fft_driver.ko` выполняется без ошибок
- `dmesg | grep fft` показывает загрузку драйвера
- `/dev/fft_0` доступен для чтения/записи

---

### Этап 5: User-space библиотека (Неделя 14–16)

**Задачи:**
- Реализация C library `libfft.so` с FFTW-compatible API
- Python bindings (ctypes/CFFI)
- Примеры (C и Python)
- Unitize тесты

**Выходные данные:**
- `libfft.c` + `libfft.h`
- `libfft_py.py` (Python wrapper)
- `examples/` (3–5 примеров)
- `tests/` (unit тесты)

**Критерии завершения:**
- C API функционирует без утечек памяти (valgrind check)
- Python примеры запускаются успешно
- Все тесты проходят

---

### Этап 6: Интеграционное тестирование (Неделя 17–18)

**Задачи:**
- End-to-end тестирование (input → FPGA → output)
- Сравнение с CPU FFT (NumPy)
- Профилирование производительности
- Стресс-тесты

**Выходные данные:**
- `tests/integration_test.py`
- `benchmarks/performance_report.md`
- Серия тестовых сигналов

**Критерии завершения:**
- Точность совпадает с NumPy (< 2 LSB)
- FPGA FFT быстрее чем CPU на заданных размерах

---

### Этап 7: Документирование (Неделя 19–20)

**Задачи:**
- API документация (Doxygen)
- User guide (Markdown)
- Примеры code snippets
- Troubleshooting guide

**Выходные данные:**
- `docs/API.md`
- `docs/USER_GUIDE.md`
- `docs/ARCHITECTURE.md`
- `LICENSE` (BSD/MIT)

---

## 5. Технические спецификации

### 5.1 FFT Engine

#### Параметры

```verilog
parameter FFT_SIZE = 64;           // 32, 64, 128
parameter INPUT_WIDTH = 16;         // бит
parameter OUTPUT_WIDTH = 20;        // бит
parameter TWIDDLE_WIDTH = 16;       // бит
parameter LATENCY = 80;             // циклов для 64-pt FFT
```

#### Интерфейсы

**Входные:**
```
i_clk          : System clock (50 MHz)
i_rst          : Async reset (active high)
i_valid        : Input valid strobe
i_real[15:0]   : Real part of input
i_imag[15:0]   : Imaginary part of input (если нужно)
i_ce           : Clock enable
```

**Выходные:**
```
o_valid        : Output valid strobe
o_real[19:0]   : Real part of output
o_imag[19:0]   : Imaginary part (после вычисления)
o_index[6:0]   : Bin index (0 to FFT_SIZE-1)
```

#### Производительность

| FFT Size | Throughput | Latency | DSP Blocks |
|----------|-----------|---------|-----------|
| 32 | 1 sps | 40 cycles | 0 (soft mult) |
| 64 | 1 sps | 80 cycles | 0 |
| 128 | 1 sample/2 clk | 160 cycles | 0 |

#### Временна́я диаграмма (64-точечная FFT)

```
         ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐
clk    ──┘  └──┘  └──┘  └──┘  └──┘  └──┘  └──┘  └──┘  └──

i_valid ──────┐                                   ┌──────
              └───────────────────────────────────┘
              |________ 64 отсчёта _______________|
              0  1  2                        62  63

i_real  ──X────X────X── ... ──X────X──────────────────
              D0   D1              D62  D63

i_imag  ──X────X────X── ... ──X────X──────────────────
              D0   D1              D62  D63

                                  |←── latency=80 clk ──→|

o_valid ──────────────────────────────────────┐     ┌──
                                               └─────┘
                                               | 64  |
o_real  ───────────────────────────────────X────X────X──
                                            B0   B1
o_index ───────────────────────────────────X────X────X──
                                            0    1
```

**Примечания**:
- Входные данные загружаются последовательно (один отсчёт за такт при `i_valid=1`)
- После загрузки 64-го отсчёта идёт вычислительная задержка 80 тактов
- Выходные данные выдаются последовательно с `o_valid=1` и биновым индексом `o_index`
- Входной FIFO блокирует приём при `i_valid=1` во время вычисления (backpressure)

#### Диаграмма состояний FSM (Finite State Machine)

```
          ┌─────────┐
          │  IDLE   │◄────────────────────────────┐
          └────┬────┘                             │
               │ i_valid=1 && enable=1             │
               ▼                                  │
          ┌─────────┐                             │
          │  LOAD   │ (приём 64 отсчётов)          │
          └────┬────┘                             │
               │ cnt == FFT_SIZE                  │
               ▼                                  │
          ┌─────────┐                             │
          │  EXEC   │ (вычисление, 80 циклов)      │
          └────┬────┘                             │
               │ done                              │
               ▼                                  │
          ┌─────────┐      ┌──────────┐           │
          │ OUTPUT  │──────►│  ERROR   │ (если     │
          └────┬────┘      └──────────┘ overflow)  │
               │ last_sample                        │
               └───────────────────────────────────┘
```

### 5.2 AXI Lite Register Map

| Адрес | Имя | Бит | Тип | Описание |
|-------|-----|-----|-----|----------|
| 0x00 | CONTROL | [31:0] | R/W | Бит 0: enable, Бит 1: reset, Бит 2: interrupt_en |
| 0x04 | STATUS | [31:0] | R | Бит 0: ready, Бит 1: busy, Бит 2: error |
| 0x08 | CONFIG | [31:0] | R/W | Бит [4:0]: FFT_SIZE (log2), Бит [9:5]: window_type |
| 0x0C | DATA_IN | [31:0] | W | Input FIFO (real в [15:0], imag в [31:16]) |
| 0x10 | DATA_OUT | [31:0] | R | Output FIFO (real в [19:0], imag в [39:20]) |
| 0x14 | FIFO_STAT | [31:0] | R | Бит [7:0]: input level, Бит [15:8]: output level |
| 0x18 | VERSION | [31:0] | R | 0x01000000 (v1.0.0) |
| 0x1C | IRQ_STATUS | [31:0] | R/W1C | Бит 0: computation_done, Бит 1: fifo_overflow, Бит 2: fifo_underflow, Бит 3: config_error |
| 0x20 | IRQ_MASK | [31:0] | R/W | Маска прерываний (1 = разрешено): биты соответствуют IRQ_STATUS |
| 0x24 | ERROR_CODE | [31:0] | R | Код последней ошибки (0 = нет ошибок) |

#### Карта прерываний

| IRQ | Бит | Источник | Приоритет | Обработчик |
|-----|------|----------|-----------|------------|
| 0 | `computation_done` | Завершение FFT-вычисления | Низкий | Чтение выходного FIFO |
| 1 | `fifo_overflow` | Переполнение входного FIFO | Высокий | Сброс FIFO, повторная передача |
| 2 | `fifo_underflow` | Попытка чтения пустого выходного FIFO | Средний | Ожидание данных |
| 3 | `config_error` | Некорректная конфигурация (размер/окно) | Критический | Сброс конфигурации на значения по умолчанию |

#### Коды ошибок

| Код | Имя | Описание | Действие |
|------|------|----------|----------|
| 0x00 | `ERR_NONE` | Нет ошибок | — |
| 0x01 | `ERR_FIFO_OVF` | Входной FIFO переполнен | Сброс входного FIFO |
| 0x02 | `ERR_FIFO_UDF` | Выходной FIFO опустошён | Ожидание вычисления |
| 0x03 | `ERR_CFG_SIZE` | Неподдерживаемый размер FFT | Сброс на FFT_SIZE=64 |
| 0x04 | `ERR_CFG_WIN` | Неподдерживаемый тип окна | Сброс на Hann |
| 0x05 | `ERR_TIMEOUT` | Аппаратный тайм-аут (> 10 000 циклов) | Сброс FFT-ядра

### 5.3 Linux Driver

**Module name**: `fft_driver`  
**Device**: `/dev/fft_0`  
**Class**: `fft`

**ioctl Codes**:
```c
#define FFT_IOCTL_MAGIC 'F'
#define FFT_GET_CONFIG    _IOR(FFT_IOCTL_MAGIC, 1, struct fft_config)
#define FFT_SET_CONFIG    _IOW(FFT_IOCTL_MAGIC, 2, struct fft_config)
#define FFT_RESET         _IO(FFT_IOCTL_MAGIC, 3)
#define FFT_GET_STATUS    _IOR(FFT_IOCTL_MAGIC, 4, struct fft_status)
```

---

## 6. Требования к оборудованию и ПО

### 6.1 Оборудование

- **ICEZero (ICE40HX4K)**: 1 шт.
- **Raspberry Pi 4/5**: 1 шт. (хост-контроллер)
- **Micro-USB кабель** (для питания Pi)
- **ПК с Linux** (для разработки, подключается к Pi по SSH)

### 6.2 Программное обеспечение

#### Обязательно
- Project IceStorm (Yosys, nextpnr, icepack, iceprog)
- GCC toolchain
- Python 3.8+
- GNU Make

#### Опционально
- Verilator (симуляция)
- GTKWave (просмотр VCD)
- Doxygen (документация)
- GDB (отладка)

#### Версии

```bash
# Проверка версий
yosys --version          # >= 0.30
nextpnr-ice40 --version # >= 0.40
python3 --version       # >= 3.8
gcc --version           # >= 9.0
```

---

## 7. Структура репозитория

```
ice40-fft/
├── README.md                    # Главная документация
├── LICENSE                      # MIT/BSD license
├── Makefile                     # Top-level makefile
├── config.mk                    # Build config (paths, ARM toolchain)
│
├── .config/
│   ├── pi_address.txt          # Raspberry Pi IP/hostname (для SSH deploy)
│   ├── pi_user.txt             # SSH username (default: pi)
│   └── toolchain.cfg           # ARM cross-compiler paths
│
├── docs/
│   ├── SETUP.md                # Installation guide (PC + Pi)
│   ├── ARCHITECTURE.md         # System architecture
│   ├── DEVELOPMENT.md          # Development workflow (NEW)
│   ├── DEPLOYMENT.md           # SSH deployment guide (NEW)
│   ├── REMOTE_TESTING.md       # Remote testing via SSH (NEW)
│   ├── API.md                  # API reference
│   ├── HARDWARE_GUIDE.md       # Hardware connections
│   └── TROUBLESHOOTING.md      # FAQ
│
├── hardware/
│   ├── rtl/
│   │   ├── fft_core.v
│   │   ├── axi_lite_slave.v
│   │   ├── fifo_256.v          # 256 bytes (более оптимально для HX4K)
│   │   ├── uart_115200.v
│   │   ├── gpio_ctrl.v
│   │   ├── sram_ctrl.v         # (NEW) Контролер для 4M SRAM
│   │   ├── top_design.v
│   │   └── butterfly.v
│   │
│   ├── sim/
│   │   ├── fft_tb.v
│   │   ├── verify_fft.py
│   │   └── Makefile
│   │
│   ├── synth/
│   │   ├── Makefile            # Yosys/nextpnr targets
│   │   ├── icezero.pcf         # Pin constraints
│   │   ├── timing.sdc
│   │   └── build_scripts/
│   │       ├── synth.sh        # Синтез (Yosys)
│   │       ├── pnr.sh          # Place & route (nextpnr)
│   │       └── pack.sh         # Bitstream (icepack)
│   │
│   └── scripts/
│       ├── gen_fft.py
│       ├── gen_twiddle.py
│       └── fuse_bitstream.py
│
├── software/
│   ├── kernel_driver/
│   │   ├── fft_driver.c
│   │   ├── fft_driver.h
│   │   ├── Makefile
│   │   ├── module.lds
│   │   └── cross_compile.sh    # (NEW) Cross-compile для ARM
│   │
│   ├── lib/
│   │   ├── libfft.c
│   │   ├── libfft.h
│   │   ├── Makefile
│   │   ├── fftw_compat.h
│   │   └── arm_build.sh        # (NEW) ARM cross-compile
│   │
│   ├── python/
│   │   ├── pyfft/
│   │   │   ├── __init__.py
│   │   │   ├── fft.py
│   │   │   └── examples.py
│   │   ├── setup.py
│   │   └── build_for_pi.sh     # (NEW) Build для Pi
│   │
│   └── utils/
│       ├── fft_load.c          # Bitstream loader
│       ├── fft_test.c          # Test utility
│       ├── fft_profile.py      # Performance profiler
│       └── deploy.sh           # (NEW) SSH deploy script
│
├── examples/
│   ├── c/
│   │   ├── simple_fft.c
│   │   ├── real_time_spectrum.c
│   │   ├── Makefile
│   │   └── Makefile.arm        # (NEW) ARM cross-compile
│   │
│   └── python/
│       ├── simple_fft.py
│       ├── plot_spectrum.py
│       ├── benchmark.py
│       ├── test_on_pi.sh       # (NEW) Run tests via SSH
│       └── requirements.txt
│
├── tests/
│   ├── unit/
│   │   ├── test_fft_core.py
│   │   ├── test_fifo.py
│   │   ├── test_uart.py
│   │   └── Makefile
│   │
│   ├── integration/
│   │   ├── test_end_to_end.py
│   │   ├── test_driver.py
│   │   ├── test_on_pi.py       # (NEW) Run via SSH on Pi
│   │   └── run_remote_tests.sh # (NEW) SSH test runner
│   │
│   └── data/
│       ├── test_vectors.txt
│       └── expected_output.txt
│
├── scripts/
│   ├── setup_dev.sh            # Setup dev environment
│   ├── setup_pi.sh             # (NEW) Setup Raspberry Pi
│   ├── build_all.sh            # Build all (PC + ARM cross-compile)
│   ├── deploy_to_pi.sh         # (NEW) Deploy to Pi via SSH
│   ├── test_on_pi.sh           # (NEW) Run tests via SSH
│   ├── sync_with_pi.sh         # (NEW) Sync code via SSH
│   └── remote_shell.sh         # (NEW) SSH shell to Pi
│
├── ci/
│   ├── .github/workflows/
│   │   ├── build.yml           # Build on push
│   │   ├── test.yml            # Run unit tests
│   │   └── cross_compile.yml   # (NEW) Cross-compile for ARM
│   │
│   └── Makefile                # CI targets
│
└── .gitignore
```

---

## 8. Критерии приёмки проекта

### Критерий 1: Функциональность

- [ ] FFT на FPGA работает на всех поддерживаемых размерах (32, 64, 128)
- [ ] Результаты совпадают с NumPy FFT с точностью ≤ 2 LSB
- [ ] Тестируется на случайных входах (100+ тестов)

### Критерий 2: Производительность

- [ ] Латентность FFT ≤ 100 мкс (64-точечная)
- [ ] Пиковое потребление мощности ≤ 500 мВт
- [ ] FPGA FFT быстрее CPU версии на коротких размерах

### Критерий 3: Надёжность

- [ ] 10+ часов stress-теста без ошибок
- [ ] Обработка edge-cases (overflow, underflow, SRAM access)
- [ ] Formal verification butterfly модуля
- [ ] Тестирование при различных температурах (с Raspberry Pi thermal stress)

### Критерий 4: Linux интеграция

- [ ] Драйвер ядра загружается без ошибок на Pi: `sudo insmod fft_driver.ko`
- [ ] `/dev/fft_0` доступен и функционален на Pi
- [ ] User-space API работает на C и Python
- [ ] Нет утечек памяти (valgrind clean на Pi)
- [ ] Удаленное выполнение тестов через SSH работает

### Критерий 5: SSH deployment и remote testing

- [ ] `deploy_to_pi.sh` успешно загружает все артефакты на Pi
- [ ] `test_on_pi.sh` успешно запускает тесты через SSH
- [ ] Bitstream загружается через `iceprog` на Pi
- [ ] Все интеграционные тесты проходят на реальном железе (Pi + ICEZero)
- [ ] Нет зависимостей на specific paths на dev machine

### Критерий 6: Документация

- [ ] Все API функции документированы (Doxygen)
- [ ] `DEVELOPMENT.md` описывает workflow разработки на Linux
- [ ] `DEPLOYMENT.md` описывает deploy и testing через SSH
- [ ] User guide содержит >= 3 рабочих примеров
- [ ] Troubleshooting guide для SSH issues
- [ ] Документация на английском

### Критерий 7: Кодовая база

- [ ] Все исходники в git репозитории
- [ ] Makefile работает на чистой системе
- [ ] Нет hardcoded paths
- [ ] Соответствие coding style (MISRA-C для kernel code)

---

## 9. Риски и митигации

| Риск | Вероятность | Воздействие | Митигация |
|------|-----------|-----------|-----------|
| Недостаточно ресурсов LUT в HX4K | Средняя | Высокое | Использовать Sliding DFT вместо pipelined, оптимизация синтеза |
| Timing violations на 50 МГц | Низкая | Среднее | Консервативная стратегия P&R, анализ временны́х ограничений |
| Сложность kernel driver | Средняя | Среднее | Использовать UIO framework, избежать сложного interrupt handling |
| Несовместимость версий toolchain | Низкая | Среднее | Зафиксировать версии в документации |
| Нет встроенного DSP в HX4K | Высокая | Среднее | Soft multiplication, оптимизированный синтез |
| Проблемы с питанием от Pi | Низкая | Среднее | Мониторинг потребления, внешнее питание при необходимости |
| Деградация Flash памяти | Низкая | Низкое | Ограничение циклов перезаписи, wear leveling |

---

## 10. Интеграция с Raspberry Pi

### 10.1 HAT Interface

ICEZero подключается к Raspberry Pi через стандартный 2x20 GPIO разъём. Ключевые пины:

- **3V3**: Power (не используется, питание от 5V)
- **5V**: Main power supply (для FPGA, SRAM, всех компонентов)
- **SPI0** (GPIO8/9/10/11): Программирование bitstream и обмен данными (Mesa Bus Protocol, 32 МГц)
- **GPIO17**, **GPIO27**: Для управления и статуса (опционально)
- **I2C** (GPIO2/3): Для будущего расширения

### 10.2 Существующие примеры

На основе [cliffordwolf/icotools examples/icezero](https://github.com/cliffordwolf/icotools/tree/master/examples/icezero):

- **SUMP2 Logic Analyzer**: Реализация на FPGA, анализ сигналов с Pi
- **GPIO examples**: LED control, PWM, servo control
- **SPI communication**: Между Pi и FPGA (32 МГц SPI через Mesa Bus protocol)

### 10.3 Программирование bitstream

FPGA конфигурируется через SPI-интерфейс Raspberry Pi:

```bash
# На Raspberry Pi (основной способ):
iceprog design.bin
```

Процесс:
1. Bitstream синтезируется на dev-машине
2. `scp` загружает `.bin` на Pi
3. `iceprog` на Pi программирует FPGA через SPI0 (GPIO8–11)
4. FPGA немедленно запускает загруженную конфигурацию

Альтернативно, bitstream может быть записан в QSPI Flash на плате ICEZero для автозагрузки при подаче питания.

### 10.4 Сосуществование с другими HAT (HiFiBerry DAC+ ADC)

ICEZero использует непересекающийся набор пинов GPIO с HiFiBerry DAC+ ADC, что позволяет
одновременную работу обеих плат без конфликтов.

#### Карта занятости GPIO

| GPIO | HiFiBerry DAC+ ADC | ICEZero | Конфликт |
|------|-------------------|---------|----------|
| 2, 3 | I²C (EEPROM авто-конфигурация) | I²C (ID EEPROM + управление FPGA) | ✅ Шина I²C — совместное использование |
| 8, 9, 10, 11 | — | **SPI0** (данные + прошивка) | ✅ |
| 7 | — | SPI0 CE1 (доп. канал) | ✅ |
| 5, 6, 12, 13, 16, 26 | — | **CFG** (конфигурация FPGA) | ✅ |
| 14, 15 | — | **UART** (отладка) | ✅ |
| 18 | **I²S BCLK** | — | ✅ |
| 19 | **I²S FS (LRCK)** | — (NetP11_35, не подключён) | ✅ |
| 20 | **I²S DIN** | — (NetP11_38, не подключён) | ✅ |
| 21 | **I²S DOUT** | — (NetP11_40, не подключён) | ✅ |
| 22, 24, 25 | — | **GPIO** (управление/статус FPGA) | ✅ |
| 4, 17, 23, 27 | — | — (не подключены) | ✅ |

> **Вывод**: конфликты отсутствуют. I²C — шина с поддержкой нескольких устройств.
> HiFiBerry EEPROM: адрес 0x50. ICEZero FPGA: свободный адрес (0x30–0x3F).

#### Рекомендации по совместной работе

1. **Device Tree**: описания обоих HAT загружаются через EEPROM или вручную в `/boot/config.txt`:
   ```
   dtoverlay=hifiberry-dacplusadc
   dtoverlay=icezero-fft
   ```
2. **I²C**: драйвер ICEZero использует уникальный адрес, не конфликтующий с HiFiBerry (0x50)
3. **SPI0**: используется только ICEZero; HiFiBerry не затрагивает SPI
4. **Питание**: суммарное потребление ICEZero (≤150 мА) + HiFiBerry (<60 мА) ≤ 210 мА — в пределах возможностей Pi (500 мА на 5V)

---

### 10.5 Максимальная производительность обмена данными

#### Анализ пропускной способности

| Интерфейс | Частота | Теоретическая пропускная способность | Использование |
|-----------|--------|--------------------------------------|---------------|
| **SPI0** (основной канал) | 32 МГц | **4 МБ/с** (32 Мбит/с) | Данные FFT + регистры управления |
| SPI0 CE1 (доп. канал) | 32 МГц | 4 МБ/с | Опционально: выделенный канал данных |
| I²C | 400 кГц | 50 КБ/с | Низкоскоростная телеметрия/статус |
| UART | 115200 бод | 14 КБ/с | Отладочная консоль |

Для 64-точечной FFT с 16-битными отсчётами (complex):
- Входной блок: 64 × 4 байт = **256 байт**
- Выходной блок: 64 × 4 байт = **256 байт**
- Суммарно на одно преобразование: **512 байт**

При пропускной способности SPI 4 МБ/с: до **8000 FFT-преобразований/с**.

#### Стратегия максимальной производительности

```
┌─────────────────────────────────────────────────────────┐
│  Raspberry Pi                                           │
├─────────────────────────────────────────────────────────┤
│  User-space App (Python/C)                              │
│  └─ libfft.so                                           │
│       └─ mmap SPI buffer (DMA)                          │
├─────────────────────────────────────────────────────────┤
│  Linux Kernel                                           │
│  ├─ fft_driver.ko  (UIO, /dev/fft_0)                    │
│  ├─ spidev          (DMA, /dev/spidev0.0)               │
│  └─ Mesa Bus Protocol (packet-based)                    │
├─────────────────────────────────────────────────────────┤
│  2×20 GPIO HAT                                          │
│   ├─ SPI0 MOSI/MISO/SCLK/CE0 (32 МГц) ──► данные + cfg │
│   ├─ CFG[5:0] (GPIO5,6,12,13,16,26) ──► загрузка FPGA │
│   └─ I²C (GPIO2,3) ──► телеметрия/статус                │
└──────────────────────┬──────────────────────────────────┘
                       │
         ┌─────────────▼──────────────────┐
         │  Протокол Mesa Bus (пакетный)   │
         │  ┌──────────────────────────┐  │
         │  │ Header (4B)              │  │
         │  │ ├─ CMD: R/W (2b)         │  │
         │  │ ├─ ADDR: reg addr (14b)  │  │
         │  │ └─ LEN: payload len (16b)│  │
         │  ├──────────────────────────┤  │
         │  │ Payload (0–65535 B)      │  │
         │  └──────────────────────────┘  │
         └─────────────┬──────────────────┘
                       │
         ┌─────────────▼──────────────────┐
         │  ICEZero FPGA                  │
         │  ├─ SPI Slave (32 МГц)         │
         │  ├─ Mesa Bus decoder           │
         │  ├─ FFT Engine                 │
         │  └─ SRAM buffer (512 КБ)       │
         └────────────────────────────────┘
```

#### Оптимизации

| Техника | Прирост | Описание |
|---------|---------|----------|
| **DMA через spidev** | +40–60% | Прямой доступ к памяти без CPU; `SPI_IOC_MESSAGE` с большими буферами |
| **Пакетный протокол (Mesa Bus)** | +20–30% | Один заголовок на блок данных вместо побайтового обмена |
| **Двойная буферизация** | +30–50% | Пинг-понг буферы в SRAM: запись/чтение параллельно с вычислением |
| **SPI CE1 как второй канал** | ×2 | Раздельные каналы для команд и данных |
| **Тактовая частота 50 МГц** | +56% | Разгон SPI за пределы спецификации (требует проверки на практике) |
| **Аппаратный Mesa Bus в FPGA** | +15–20% | Декодирование пакетов на стороне FPGA без soft-CPU |

#### Ожидаемая производительность (64-pt FFT)

| Режим | Пропускная способность | FFT/с | Латентность |
|-------|----------------------|-------|------------|
| Базовый (PIO, 32 МГц) | ~2 МБ/с | ~4000 | ~250 мкс |
| DMA + Mesa Bus | ~3.5 МБ/с | ~7000 | ~140 мкс |
| DMA + Dual Buffer + 2×SPI | ~7 МБ/с | ~14000 | ~70 мкс |
| Теоретический предел SPI0 | 4 МБ/с | ~8000 | ~125 мкс |

---

## 11. План работ и ресурсы

### 11.1 Календарный план

| Этап | Недели | Статус |
|------|--------|--------|
| 1. Подготовка окружения | 1–2 | Ожидается |
| 2. FFT ядро | 3–6 | Ожидается |
| 3. Периферия | 7–10 | Ожидается |
| 4. Linux драйвер | 11–13 | Ожидается |
| 5. User-space библиотека | 14–16 | Ожидается |
| 6. Интеграция и тесты | 17–18 | Ожидается |
| 7. Документирование | 19–20 | Ожидается |
| **Итого** | **20 недель** | |

### 11.2 Трудовые ресурсы

| Роль | Загрузка | Компетенции |
|------|----------|------------|
| Инженер FPGA/RTL | 1.0 FTE | Verilog, Yosys/nextpnr, цифровая схемотехника |
| Инженер Linux kernel/driver | 0.5 FTE | C, Linux kernel API, UIO framework, кросс-компиляция ARM |
| Инженер по тестированию и документации | 0.5 FTE | Python, pytest, Sphinx/Doxygen, технический английский |

### 11.3 Бюджет оборудования

| Позиция | Количество | Цена, USD | Сумма, USD |
|---------|-----------|----------|-------|
| ICEZero (TE0876-03-A) | 1 | 25 | 25 |
| Raspberry Pi 4/5 | 1 | 55 | 55 |
| Micro-USB кабель | 1 | 2 | 2 |
| Провода, джамперы, макетная плата | — | — | 10 |
| **Итого** | | | **92 USD** |

---

## 12. Согласования и утверждения

| Роль | Имя | Подпись | Дата |
|------|------|---------|------|
| Автор ТЗ | | _________ | _________ |
| Инженер FPGA | | _________ | _________ |
| Инженер Linux | | _________ | _________ |
| Ведущий инженер | | _________ | _________ |
| Утверждающий | | _________ | _________ |

---

## 13. Типичный workflow разработки

### Начало работы

```bash
# 1. Clone repository
git clone https://github.com/ipmgroup/fftd.git
cd fftd

# 2. Setup development environment
./scripts/setup_dev.sh

# 3. Configure Raspberry Pi address
echo "rpia5" > .config/pi_address.txt
echo "pi" > .config/pi_user.txt
```

### Development cycle

```bash
# 1. Compile HDL, run simulation
make -C hardware/sim

# 2. Synthesize FPGA design
make -C hardware/synth synth_ice40

# 3. Build kernel driver (cross-compile for ARM)
make -C software/kernel_driver ARM_CROSS=arm-linux-gnueabihf-

# 4. Build user-space library (ARM)
make -C software/lib ARM_CROSS=arm-linux-gnueabihf-

# 5. Build examples (ARM)
make -C examples/c ARM_CROSS=arm-linux-gnueabihf-

# 6. Deploy to Raspberry Pi
./scripts/deploy_to_pi.sh

# 7. Run integration tests on Pi via SSH
./scripts/test_on_pi.sh
```

### One-liner для полной сборки и тестирования

```bash
# Clean, build все (simulation, synthesis, cross-compile), deploy to Pi и run tests
make clean all && ./scripts/deploy_to_pi.sh && ./scripts/test_on_pi.sh
```

### Quick development loop (только software изменения)

```bash
# Быстрый цикл без resynthesis
make -C software/lib ARM_CROSS=arm-linux-gnueabihf- clean all && \
  ./scripts/deploy_to_pi.sh && ./scripts/test_on_pi.sh
```

### Remote development (vim/nano на Pi через SSH)

```bash
# SSH shell на Pi для quick edits
./scripts/remote_shell.sh

# Или use sshfs для mount Pi directories
sshfs pi@rpia5:/home/pi ~/mnt/pi
# Теперь можно editing файлы локально, сохранение синхронизируется
```

---

## 14. Примеры скриптов

### 14.1 deploy_to_pi.sh — SSH-развёртывание

```bash
#!/bin/bash
set -e

PI_ADDR=$(cat .config/pi_address.txt)
PI_USER=$(cat .config/pi_user.txt)
PI_HOST="${PI_USER}@${PI_ADDR}"
REMOTE_DIR="/tmp/ice40-fft"

echo "📦 Deploying to ${PI_HOST}..."

# Create remote directory
ssh ${PI_HOST} "mkdir -p ${REMOTE_DIR}"

# Copy bitstream
echo "📥 Uploading bitstream..."
scp build/design.bin ${PI_HOST}:${REMOTE_DIR}/

# Copy kernel driver
echo "📥 Uploading kernel driver..."
scp software/kernel_driver/*.ko ${PI_HOST}:${REMOTE_DIR}/ 2>/dev/null || true

# Copy libs and binaries
echo "📥 Uploading libraries..."
scp software/lib/libfft.so* ${PI_HOST}:${REMOTE_DIR}/ 2>/dev/null || true
scp examples/c/fft_test ${PI_HOST}:${REMOTE_DIR}/ 2>/dev/null || true

# Copy Python scripts
echo "📥 Uploading Python modules..."
scp -r software/python/pyfft ${PI_HOST}:${REMOTE_DIR}/ 2>/dev/null || true

# Load bitstream on Pi
echo "⚡ Loading bitstream on Pi..."
ssh ${PI_HOST} "cd ${REMOTE_DIR} && \
  iceprog design.bin && \
  echo '✅ Bitstream loaded successfully'"

echo "✅ Deployment complete!"
```

### 14.2 test_on_pi.sh — удалённое тестирование по SSH

```bash
#!/bin/bash
set -e

PI_ADDR=$(cat .config/pi_address.txt)
PI_USER=$(cat .config/pi_user.txt)
PI_HOST="${PI_USER}@${PI_ADDR}"
REMOTE_DIR="/tmp/ice40-fft"

echo "🧪 Running tests on ${PI_HOST}..."

# Load kernel driver
echo "📍 Loading kernel driver..."
ssh ${PI_HOST} "cd ${REMOTE_DIR} && \
  sudo insmod fft_driver.ko && \
  echo '✅ Driver loaded'"

# Wait for device
sleep 1

# Run C tests
if [ -f ${REMOTE_DIR}/fft_test ]; then
  echo "🧪 Running C tests..."
  ssh ${PI_HOST} "cd ${REMOTE_DIR} && ./fft_test"
fi

# Run Python tests
echo "🧪 Running Python tests..."
ssh ${PI_HOST} "cd ${REMOTE_DIR} && \
  export PYTHONPATH=. && \
  python3 -m pytest tests/ -v"

# Unload driver
echo "📍 Unloading kernel driver..."
ssh ${PI_HOST} "sudo rmmod fft_driver"

echo "✅ All tests passed!"
```

### 14.3 Makefile для кросс-компиляции

**software/lib/Makefile.arm**:
```makefile
CC := arm-linux-gnueabihf-gcc
AR := arm-linux-gnueabihf-ar
CFLAGS := -Wall -O2 -fPIC
LDFLAGS := -shared

lib: libfft.so

libfft.so: libfft.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

install:
	cp libfft.so /usr/local/lib/
	cp libfft.h /usr/local/include/

clean:
	rm -f libfft.so *.o
```

### 14.4 config.mk — конфигурация сборки

```makefile
# Development Machine
HOST_ARCH := x86_64
HOST_CC := gcc
HOST_CFLAGS := -Wall -O2 -g

# Target (Raspberry Pi)
TARGET_ARCH := armhf
ARM_CROSS := arm-linux-gnueabihf-
ARM_CC := $(ARM_CROSS)gcc
ARM_CFLAGS := -Wall -O2 -march=armv7-a -mfpu=neon

# FPGA
FPGA_DEVICE := ice40hx4k
FPGA_PACKAGE := tq144
FPGA_SPEED := 5

# Remote Pi
PI_ADDR ?= $(shell cat .config/pi_address.txt 2>/dev/null || echo "rpia5")
PI_USER ?= $(shell cat .config/pi_user.txt 2>/dev/null || echo "pi")
PI_HOST := $(PI_USER)@$(PI_ADDR)
REMOTE_DIR := /tmp/ice40-fft

# Toolchain paths
YOSYS := yosys
NEXTPNR := nextpnr-ice40
ICEPACK := icepack
ICEPROG := iceprog

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  make synth        - Synthesize HDL"
	@echo "  make sim          - Run simulation"
	@echo "  make arm-lib      - Cross-compile library for ARM"
	@echo "  make arm-driver   - Cross-compile kernel driver"
	@echo "  make deploy       - Deploy to Pi via SSH"
	@echo "  make test-remote  - Run tests on Pi"
```

---

## 15. Метрологическое обеспечение

### 15.1 Средства измерений

| Измеряемый параметр | Средство измерения | Погрешность |
|---------------------|-------------------|-------------|
| Точность FFT (ошибка) | Сравнение с NumPy FFT (double precision) | ≤ 1 LSB (эталон) |
| Латентность FFT | Осциллограф или логический анализатор (≥ 100 МГц) | ±10 нс |
| Тактовая частота FPGA | Частотомер / осциллограф | ±1 ppm |
| Потребляемая мощность | Мультиметр (ток) × напряжение, или USB power meter | ±5 мА, ±0.1 В |
| Уровни сигналов GPIO | Осциллограф / логический анализатор | ±0.1 В |

### 15.2 Методика проверки точности FFT

1. Генерация набора из N ≥ 100 случайных тестовых векторов на хосте (Python/NumPy)
2. Вычисление эталонного FFT (numpy.fft.fft, double precision) для каждого вектора
3. Передача векторов в FPGA, чтение результатов
4. Вычисление максимальной абсолютной ошибки: $\max |\text{FPGA}_k - \text{NumPy}_k|$
5. Критерий: ошибка ≤ 2 LSB выходной разрядности для 99.9% отсчётов

### 15.3 Поверка средств измерений

Все средства измерений должны иметь действующее свидетельство о поверке (при промышленном применении). Для лабораторного прототипа — калибровка по внутренним стандартам.

---

## 16. Порядок контроля и приёмки

### 16.1 Виды испытаний

| Вид испытаний | Этап | Исполнитель |
|---------------|------|-------------|
| Предварительные (лабораторные) | Этапы 2–5 | Инженер FPGA |
| Приёмо-сдаточные | Этап 6 | Комиссия |
| Периодические | После сдачи | Инженер по качеству (опционально) |

### 16.2 Программа предварительных испытаний

1. **Проверка RTL-симуляции**: все testbench проходят без ошибок (iverilog/Verilator)
2. **Проверка синтеза**: Yosys + nextpnr завершаются без критических предупреждений, утилизация LUT < 80%
3. **Проверка модулей**: Unit-тесты FIFO, UART, GPIO, AXI Lite slave
4. **Проверка FFT-ядра**: ошибка < 1 LSB против NumPy на 100 случайных векторах
5. **Проверка драйвера**: `insmod`/`rmmod` без ошибок, `/dev/fft_0` доступен, valgrind clean

### 16.3 Программа приёмо-сдаточных испытаний

1. **Функциональное тестирование**: End-to-end FFT на 32, 64, 128 точках
2. **Тестирование точности**: ошибка ≤ 2 LSB на всех поддерживаемых размерах
3. **Тестирование производительности**: латентность ≤ 100 мкс (64-точечная), тактовая частота ≥ 50 МГц
4. **Нагрузочное тестирование**: 10 часов непрерывной работы без ошибок
5. **Проверка документации**: полный комплект согласно разделу 17
6. **Проверка SSH-развёртывания**: `deploy_to_pi.sh` + `test_on_pi.sh` успешно

### 16.4 Критерии приёмки

Система считается принятой, если все приёмо-сдаточные испытания пройдены с положительным результатом. Результаты оформляются актом приёмки.

---

## 17. Требования к документированию

### 17.1 Состав документации

| Документ | Формат | ГОСТ / Стандарт |
|----------|--------|------------------|
| Техническое задание (настоящий документ) | Markdown / PDF | ГОСТ 34.602-2020 |
| Пояснительная записка к техническому проекту | Markdown / PDF | ГОСТ 19.404-79 |
| Спецификация модулей RTL | Markdown | Внутренний стандарт |
| API-документация (Doxygen) | HTML / PDF | Doxygen style |
| Руководство пользователя | Markdown / PDF | ГОСТ 19.505-79 |
| Руководство по развёртыванию | Markdown | Внутренний стандарт |
| Программа и методика испытаний | Markdown / PDF | ГОСТ 19.301-79 |
| Исходные коды (RTL, C, Python) | Текстовые файлы | В git-репозитории |
| Принципиальная схема соединений | PNG / PDF | Внутренний стандарт |

### 17.2 Требования к оформлению

- Документация ведётся на русском языке; технические термины — на английском
- Исходные тексты документации — в формате Markdown, финальные версии — PDF
- Все API-функции документированы в формате Doxygen
- Комментарии в исходном коде — на английском языке

---

## 18. Состав работ по вводу в эксплуатацию

| № | Работа | Исполнитель | Длительность |
|----|--------|-------------|-------------|
| 1 | Установка Raspberry Pi OS и обновление до актуальной версии | Инженер Linux | 2 часа |
| 2 | Установка Project IceStorm toolchain на Raspberry Pi | Инженер Linux | 1 час |
| 3 | Физическая установка платы ICEZero на HAT-коннектор Pi | Инженер FPGA | 15 минут |
| 4 | Проверка соединений и целостности питания | Инженер FPGA | 15 минут |
| 5 | Загрузка тестового bitstream (LED blink) через `iceprog` | Инженер FPGA | 15 минут |
| 6 | Кросс-компиляция и развёртывание драйвера `fft_driver.ko` | Инженер Linux | 1 час |
| 7 | Загрузка рабочего bitstream и проверка `/dev/fft_0` | Инженер FPGA + Linux | 30 минут |
| 8 | Запуск интеграционных тестов | Инженер по тестированию | 2 часа |
| 9 | Обучение пользователей (опционально) | Ведущий инженер | 2 часа |

---

## Ссылки и источники

### FFT Генераторы и ядра

- **ZipCPU dblclockfft**: https://github.com/ZipCPU/dblclockfft
- **ICE40 FFT пример**: https://github.com/mattvenn/fpga-fft
- **Sliding DFT**: https://github.com/mattvenn/fpga-sdft
- **OpenCores FFT**: https://opencores.org/projects/versatile_fft

### Linux driver frameworks

- **Linux FPGA Subsystem**: https://kernel.org/doc/html/latest/driver-api/fpga/
- **UIO Framework**: https://kernel.org/doc/html/latest/driver-api/uio-howto.html
- **Device drivers book**: https://lwn.net/Kernel/LDD3/

### Project IceStorm

- **Main project**: http://www.clifford.at/icestorm/
- **Nextpnr**: https://github.com/YosysHQ/nextpnr
- **Yosys**: https://github.com/YosysHQ/yosys
- **icotools (examples/icezero)**: https://github.com/cliffordwolf/icotools/tree/master/examples/icezero

### ICEZero Специфичные ресурсы

- **Trenz Electronic продукт**: https://www.trenz-electronic.de/de/IceZero-mit-Lattice-ICE40HX-4-Mbit-externer-SRAM-3-05-x-6-5-cm/TE0876-03-A
- **Pinout**: https://www.trenz-electronic.de/Downloads/?path=Trenz_Electronic/Pinout
- **Trenz Wiki TE0876**: https://wiki.trenz-electronic.de/display/PD/TE0876+Resources
- **Support Forum**: https://forum.trenz-electronic.de/

---

**Версия документа**: 1.0  
**Последнее обновление**: 2026-05-30  
**Статус**: Ready for Implementation