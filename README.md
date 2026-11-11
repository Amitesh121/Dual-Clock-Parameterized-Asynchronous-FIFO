# Parameterized Dual-Clock Asynchronous FIFO (CDC Subsystem)

A synthesizable, production-grade **Asynchronous Dual-Clock FIFO** designed in Verilog-2001. This block enables safe, high-throughput data transfer between completely asynchronous, independent clock domains ($f_{WCLK} \neq f_{RCLK}$) using multi-stage synchronizers and Gray-coded pointer comparisons to prevent metastability and data corruption.

---

## 1. Architectural Overview

In multi-clock SoC and networking ASICs, passing data across asynchronous clock domains introduces the risk of **metastability** in flip-flops. This design adopts the canonical Clifford E. Cummings architecture, dividing the subsystem into modular, clock-isolated components:

```text
               +-------------------------------------------------------+
               |                  Dual-Port SRAM Array                 |
               |                     (fifomem.v)                       |
               +-------------------------------------------------------+
                     ^ wdata / waddr                   raddr |
                     |                                       v rdata
    +----------------+----------------+     +----------------+----------------+
    |         wptr_full.v             |     |         rptr_empty.v            |
    |                                 |     |                                 |
    |  - Binary counter (wbin)        |     |  - Binary counter (rbin)        |
    |  - Binary-to-Gray conv (wptr)   |     |  - Binary-to-Gray conv (rptr)   |
    |  - Full flag generation (wfull) |     |  - Empty flag gen (rempty)      |
    +----------------+----------------+     +----------------+----------------+
            ^                |                       ^                |
            | rq2_wptr       | wptr                  | wq2_rptr       | rptr
            |                v                       |                v
    +-------+--------+   +---+---+               +---+---+   +--------+-------+
    | 2-Stage DFF    |   |  CDC  |               |  CDC  |   | 2-Stage DFF    |
    | Synchronizer   |   |   |   |               |   |   |   | Synchronizer   |
    |  (sync_r2w.v)  |   |   +-------------------+   |   |  (sync_w2r.v)  |
    +----------------+   +---------------------------+   +----------------+
      Clock: wclk                                          Clock: rclk
```

### Module Breakdown

| Module | Clock Domain | Description |
| :--- | :--- | :--- |
| `fifomem.v` | `wclk` (write) | Parameterized dual-port SRAM array. Writes on `wclk` when `winc & !wfull`; reads combinational/registered on `raddr`. |
| `sync_w2r.v` | `rclk` | 2-stage Flip-Flop synchronizer safely passing Gray-coded `wptr` into the read clock domain (`wq2_rptr`). |
| `sync_r2w.v` | `wclk` | 2-stage Flip-Flop synchronizer safely passing Gray-coded `rptr` into the write clock domain (`rq2_wptr`). |
| `rptr_empty.v` | `rclk` | Manages read address generation, Gray conversion, and pessimistic `rempty` flag assertion. |
| `wptr_full.v` | `wclk` | Manages write address generation, Gray conversion, and pessimistic `wfull` flag assertion. |
| `async_fifo.v` | Top-level | Structural wrapper instantiating and interconnecting the sub-blocks. |

---

## 2. Theory of Operation & CDC Protection

### Why Binary Counters Cannot Cross Clock Boundaries
A standard binary counter incrementing from `3` (`011`) to `4` (`100`) changes 3 bits simultaneously. Due to routing skew and process-voltage-temperature (PVT) variation, the capturing clock domain may sample intermediate values (e.g., `010`, `000`, `111`), leading to invalid pointers and false empty/full decisions.

### Gray-Code Conversion
Gray code guarantees that **only 1 bit changes per increment**:
$$\text{Gray} = \text{Binary} \oplus (\text{Binary} \gg 1)$$

$$\text{Binary}[i] = \bigoplus_{j=i}^{\text{MSB}} \text{Gray}[j]$$

If the destination clock samples during a Gray-code transition, the sampled pointer will resolve to either the **old value** or the **new value**, never an intermediate illegal state.

### Flag Condition Proofs

The pointers use an extra bit (`ADDRSIZE` instead of `ADDRSIZE-1`) to distinguish between **Full** and **Empty** states when pointer addresses wrap around:

1. **FIFO Empty (`rempty`):**
   * Occurs when the next read Gray pointer equals the synchronized write Gray pointer:
     $$\text{rempty\_val} = (\text{rgray\_next} == \text{rq2\_wptr})$$

2. **FIFO Full (`wfull`):**
   * Occurs when the write pointer has wrapped around exactly once more than the read pointer.
   * In binary: $\text{wbin}[\text{MSB}] \neq \text{rbin}[\text{MSB}]$, while all other address bits match: $\text{wbin}[\text{MSB}-1:0] == \text{rbin}[\text{MSB}-1:0]$.
   * In Gray code, this equates to inverting the top **two** most significant bits while the remaining bits remain identical:
     $$\text{wfull\_val} = (\text{wgray\_next} == \{\sim\text{wq2\_rptr}[\text{ASIZE}:\text{ASIZE}-1], \text{wq2\_rptr}[\text{ASIZE}-2:0]\})$$

### Pessimistic Flag Property (Safety by Design)
Because pointers pass through a 2-flip-flop synchronizer (introducing 2 destination clock cycles of latency):
* **Full Flag:** The write domain sees a *delayed* version of the read pointer. The FIFO may report `full` even if the read domain has just consumed words, which is 100% safe (prevents overflow).
* **Empty Flag:** The read domain sees a *delayed* version of the write pointer. The FIFO may report `empty` even if new data was just pushed, which is 100% safe (prevents underflow).

---

## 3. Parameter Specifications & Port List

### Parameters

| Parameter | Default | Range | Description |
| :--- | :--- | :--- | :--- |
| `DSIZE` | `8` | $\ge 1$ | Data bus width (bits per word). |
| `ASIZE` | `4` | $\ge 2$ | Address bus width. Total FIFO depth = $2^{\text{ASIZE}}$ (Default: 16 words). |

### Top-Level Interface (`async_fifo`)

| Port | Direction | Domain | Description |
| :--- | :--- | :--- | :--- |
| `wclk` | Input | Write Domain | Write clock input. |
| `wrst_n` | Input | Write Domain | Active-low asynchronous reset (write domain). |
| `winc` | Input | Write Domain | Write enable/increment. |
| `wdata[DSIZE-1:0]` | Input | Write Domain | Write data bus. |
| `wfull` | Output | Write Domain | FIFO full indicator. Synchronous to `wclk`. |
| `rclk` | Input | Read Domain | Read clock input. |
| `rrst_n` | Input | Read Domain | Active-low asynchronous reset (read domain). |
| `rinc` | Input | Read Domain | Read enable/increment. |
| `rdata[DSIZE-1:0]` | Output | Read Domain | Read data bus. Synchronous to `rclk`. |
| `rempty` | Output | Read Domain | FIFO empty indicator. Synchronous to `rclk`. |

---

## 4. Testbench & Verification Plan

The self-checking testbench verifies functionality under real-world multi-clock corner cases:

1. **Asynchronous Frequency Ratio:**
   * Write Clock: $100\text{ MHz}$ ($T = 10\text{ ns}$)
   * Read Clock: $\approx 71.4\text{ MHz}$ ($T = 14\text{ ns}$)
2. **Burst Write (Fill to Capacity):** 16 consecutive writes to confirm `wfull` asserts accurately on depth boundary.
3. **Overflow Protection Check:** Deliberate write attempt while `wfull = 1` to verify memory integrity is maintained and pointer does not increment.
4. **Burst Read (Drain to Empty):** 16 consecutive reads to confirm `rempty` asserts and pipeline empties without data loss.
5. **Underflow Protection Check:** Deliberate read attempt while `rempty = 1` to ensure no corrupted output or illegal pointer advance.
6. **Concurrent Bidirectional Stress:** Concurrent pseudo-random read and write transactions crossing clock domains simultaneously.

---

## 5. Running on EDA Playground

1. Go to [EDA Playground](https://www.edaplayground.com/).
2. In the left configuration panel:
   * **Testbench + Design:** `SystemVerilog/Verilog`
   * **Simulator:** `Icarus Verilog 0.10.0` or `Aldec Riviera Pro`
   * Check **Open EPWave after run**
3. Paste the design source code into `design.sv`.
4. Paste the testbench source code into `testbench.sv`.
5. Click **Run**.

---
