# XRDAP-SWD-Probe

> Open SWD probe (discrete + FPGA) with XRDAP adapter  
> 开源 SWD 探针（分立元件 + FPGA），用于 XRDAP 调试器

---

## 目标 / Goals

实现一个 **成本低、结构简单、行为稳定** 的 SWD 数字前端，使任何带 SPI 接口的主机（MCU / SBC / SoC）都可以：

- 用 **固定 48bit SPI 传输 + 少量 GPIO** 完成标准 SWD 访问；
- 在访问过程中依靠 **DMA / FIFO 连续传输**，避免中途 bit-bang；
- 在较高 SWCLK 频率下，仍然满足 SWD 的 REQ / TURN / ACK / DATA / PARITY / IDLE 时序要求。

---

## 背景问题 / Pain Points

直接使用 MCU + GPIO 软件实现 SWD，常见问题包括：

1. **位宽难以与 SPI 帧对齐**  
   单次 SWD 访问约需 46 个 SWCLK 周期，不方便直接映射到 8/16bit SPI 帧。

2. **总线换向（turnaround）时序敏感**  
   REQ 之后 SWDIO 需在主机与目标之间切换，写访问还可能存在第二次换向；  
   完全由软件控制 IO 方向，在高频下容易产生方向冲突或时序误差。

3. **ACK 分支影响访问流程**  
   SWD 定义 OK / WAIT / FAULT 多种 ACK，软件需根据 ACK 决定是否进入 data phase 或执行错误恢复。  
   在 SPI + DMA 模型下，如希望高效连续传输，需要清晰的访问抽象。

---

## 总体思路 / Approach

### 1. 固定 SPI 帧 + “前 15 位有语义，之后视作 after-ACK 流”

主机侧建议：

- **固定 48bit SPI 帧**，LSB first；
- 每次 SWD 访问 = 一帧 SPI 传输（DMA 发送 6 字节）；
- 每帧开始前短暂拉低一次 `rst_n`，作为该帧的逻辑复位。

前端的抽象更简单：

- 仅在 `rst_n` 拉高后的 **前 15 个 SWCLK 上升沿** 精细区分 bit 位置；
- 第 15 个上升沿之后的所有时钟，一律视作 **“ACK 之后的比特流（after-ACK stream）”**：
  - 不再关心具体 bit 序号；
  - 不依赖“固定 48bit 帧长度”的假设；
  - 后续行为仅由「这是 ACK 之后」+ RnW + ACK 是否 OK 决定。

> 推荐使用 48bit 帧是方便软件实现；  
> 前端本身只区分“前 15 位”和“之后所有位”。

#### 1.1 前 15 位的逻辑布局（前端视角）

以 `rst_n` 从 0→1 后的 SWCLK 上升沿计数 `bit_idx = 0, 1, 2, ...` 为例：

| bit_idx | 角色             | 说明                                    |
| ------- | ---------------- | --------------------------------------- |
| 0..2    | PADDING          | 主机输出 0，用于对齐计数器              |
| 3..10   | REQ_WINDOW       | 标准 SWD Request 8bit（主机驱动 SWDIO） |
| 11      | TURN1            | REQ→ACK 的 turnaround，前端停止驱动     |
| 12..14  | ACK_WINDOW       | 目标驱动 ACK[0..2]，前端采样并解码      |
| ≥15     | AFTER_ACK_STREAM | ACK 之后的比特流，前端不再区分索引      |

ACK_WINDOW 中的 3bit 解码为：

- `001` = OK  
- `010` = WAIT  
- `100` = FAULT  
- 其他视作非法，统一 `ack_ok = 0`。

---

### 2. 事务行为（前端视角）

前端只依赖三个逻辑信号决定行为：

- `rnw`：1 = READ，0 = WRITE（由主机在访问之前拉好）；  
- `ack_ok`：ACK 是否为 `3'b001`；  
- `after_ack`：是否已经进入 AFTER_ACK_STREAM（bit_idx ≥ 15）。

在此基础上，前端只区分 4 种事务行为：

| 场景               | PADDING+REQ (0..10)   | TURN1+ACK (11..14)   | AFTER_ACK_STREAM (≥15)                    |
| ------------------ | --------------------- | -------------------- | ----------------------------------------- |
| **READ + ACK=OK**  | 主机驱动 SWDIO = MOSI | 前端高阻，目标驱 ACK | 前端高阻，目标输出 DATA+PARITY，MISO 回读 |
| **READ + ACK≠OK**  | 主机驱动 SWDIO = MOSI | 前端高阻，目标驱 ACK | 前端高阻，目标可输出任意数据或保持高阻    |
| **WRITE + ACK=OK** | 主机驱动 SWDIO = MOSI | 前端高阻，目标驱 ACK | 前端驱动 SWDIO = MOSI（连续写数据比特流） |
| **WRITE + ACK≠OK** | 主机驱动 SWDIO = MOSI | 前端高阻，目标驱 ACK | 前端保持高阻，不向目标写入任何数据        |

说明：

- **READ + ACK=OK / ACK≠OK**  
  - 在读事务中，ACK 之后前端始终高阻，数据方向始终为目标→主机；  
  - 软件仅在 ACK=OK 时，从 after-ACK 流中截取约定的 32bit DATA + 1bit PARITY，否则全部丢弃。

- **WRITE + ACK=OK**  
  - ACK 之后，前端持续驱动 SWDIO = MOSI；  
  - 软件在 MOSI 中安排写入的 32bit DATA + 1bit PARITY，其余比特作为填充或后续帧的一部分。

- **WRITE + ACK≠OK（WAIT/FAULT/非法）**  
  - ACK 之后，前端保持高阻，不写数据；  
  - 在协议层面，这一访问可以视作“只完成了 REQ + ACK”，软件据此执行重试、ABORT 或 line reset。

after-ACK 流的长度完全由软件控制：  
前端既不会在“48bit 结束”自动停表，也不会在 WAIT/FAULT 时强制切断 SWCLK，只要 `rst_n` 不被拉低，后续所有时钟都属于同一 after-ACK 流。

---

### 3. RAW 模式：line reset / SWJ / 主机自定义序列

#### 3.1 `rst_n = 0`：MOSI → SWDIO 直通

当 `rst_n = 0` 且 SCK 在运行时：

- 内部计数器和 ACK 相关状态被异步复位并保持在初始值；  
- 前端不再识别 PADDING / REQ / ACK 等窗口；  
- 组合逻辑退化为：**`swdio = mosi` 始终有效，`swclk = sck` 透传**。

此时前端等价于：

> MOSI → SWDIO 直通 + SCK → SWCLK 直通。

可用于：

- **line reset**  
  - 令 MOSI=1，输出 ≥50 个 SWCLK；  
  - 再输出若干 MOSI=0 的 idle；  

- **SWJ 切换（JTAG ↔ SWD）**  
  - 例如 JTAG→SWD：`line-reset → 0xE79E (LSB first) → line-reset → idle`；  
  - 全部在 raw 模式下通过 MOSI 比特流实现。

- **其它主机自定义序列**  
  - 任何语义上属于“主机单向输出”的控制序列均可通过 raw 模式发送。

#### 3.2 正常模式下的 idle / dummy 访问

在 `rst_n = 1` 的正常模式下，软件也可以利用 after-ACK 流构造辅助访问：

- 在一次访问结束后，继续输出 SWCLK 并选择合适的 MOSI，生成所需数量的 idle 周期；  
- 使用仅包含 REQ + ACK 的短访问帧，进行链路检测或时序对齐。

前端不会对 SWCLK 长度做强制限制，只要 `rst_n` 不拉低，均视作同一访问的 after-ACK 流。

---

## SWCLK 行为

- **正常模式 (`rst_n = 1`)**：  
  `swclk = sck`，前端不对时钟做按位 gating。  
  SWD 规范中“停表前 idle 数量”等要求由软件通过适当的 idle 或 raw 序列满足。

- **raw 模式 (`rst_n = 0`)**：  
  同样 `swclk = sck`，同时 `swdio = mosi` 直通。

---

## 实现概览 / Implementation

### 分立逻辑版本（74HC）

分立版本基于常见 74HC 器件：

- **计数器**：1 × 74HC163  
  - 4bit 位计数，用于识别 PADDING / REQ / TURN1 / ACK 窗口。  
- **移位寄存器**：1 × 74HC164  
  - 捕获前 15 个 bit，从中抽出并解码 ACK 三位。  
- **逻辑门**：74HC00（NAND）、74HC08（AND）  
  - 实现 after-ACK 标志（SR latch）、方向控制、ACK 解码等。  
- **三态缓冲**：2 × 74HC125  
  - MOSI → SWDIO（前端输出）；  
  - SWDIO → 内部 / MISO（前端输入）。

整体结构没有“隐藏状态机”，全部可以用 74HC 器件与布线实现。

### FPGA / RTL 参考实现

仓库提供一份 RTL 参考实现，便于仿真与 FPGA 原型：

- `swd_frontend_top.v`  
  - 实现“前 15 位有语义 + after-ACK 流”的前端行为。  
- `testbench_read.v`  
  - READ + ACK=OK / ACK=WAIT，验证 ACK 抽取与读通路。  
- `testbench_write.v`  
  - WRITE + ACK=OK / ACK=WAIT，验证写通路与 ACK≠OK 时 after-ACK 流不写线。  
- `testbench_special.v`  
  - raw 模式 MOSI→SWDIO 直通、ABORT 写、WRITE + FAULT 等特殊场景。

---

## 主机使用约定 / MCU Side

### SPI 建议配置

- 模式：**CPOL = 0, CPHA = 0**（上升沿采样）；  
- 位序：**LSB first**；  
- 帧长：建议 **48 bit**（方便 DMA）；  
- 频率：根据目标板信号完整性评估，通常可从几十 MHz 作为起点。

### 控制信号

- `rst_n`：  
  - 正常访问：帧前在 SCK 静止时拉低一小段时间，然后拉高并开始本次访问；  
  - raw 模式：整个序列期间保持为 0。

- `rnw`：  
  - 1 = READ，0 = WRITE；  
  - 在 `rst_n` 拉高前设置，在访问期间保持不变。

软件可在此基础上封装高层 API，例如：

- READ_OK / READ_WAIT / READ_FAULT；  
- WRITE_OK / WRITE_WAIT / WRITE_FAULT；  
- LINE_RESET / SWJ 序列；  
- ABORT / pipeline AP 访问等。

---

## 状态 / Status

- ✅ 前端方案与时序定义（前 15 位 + after-ACK 流）  
- ✅ FPGA / RTL 参考实现与基础仿真  
- ⏳ 分立元件原理图（74HC163 / 164 / 00 / 08 / 125 等）  
- ⏳ FPGA 顶层封装与 XRDAP 协议适配  
- ⏳ PCB 设计与实机测试

---

本仓库仅包含 SWD 前端相关的硬件设计文件（Verilog/RTL、原理图、PCB 等），不包含任何配套软件。

本项目依照《XRDAP-SWD 硬件许可协议 v1》发布，详见仓库中的 `LICENSE`（以中文版本为准）。

对于未被 `LICENSE` 中“禁止对象 / 禁止用途”明确列出的主体和场景：在不修改本设计文件的前提下，任何个人或商业主体均可免费使用、复制、制造和量产基于本未修改版本的硬件产品，无需额外授权或费用。
