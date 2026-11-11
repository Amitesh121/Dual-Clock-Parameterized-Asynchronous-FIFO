// 1. Dual-Port Synchronous/Asynchronous SRAM Array
module fifomem #(
    parameter DATASIZE = 8,
    parameter ADDRSIZE = 4
)(
    input  wire                 winc, wfull, wclk,
    input  wire [ADDRSIZE-1:0]  waddr, raddr,
    input  wire [DATASIZE-1:0]  wdata,
    output wire [DATASIZE-1:0]  rdata
);
    localparam DEPTH = 1 << ADDRSIZE;
    reg [DATASIZE-1:0] mem [0:DEPTH-1];

    assign rdata = mem[raddr];

    always @(posedge wclk) begin
        if (winc && !wfull)
            mem[waddr] <= wdata;
    end
endmodule

// 2. 2-Flip-Flop Synchronizer (Write to Read Domain)
module sync_w2r #(
    parameter ADDRSIZE = 4
)(
    input  wire                rclk, rrst_n,
    input  wire [ADDRSIZE:0]   wq2_rptr_in,
    output reg  [ADDRSIZE:0]   wq2_rptr
);
    reg [ADDRSIZE:0] wq1_rptr;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            wq1_rptr <= 0;
            wq2_rptr <= 0;
        end else begin
            wq1_rptr <= wq2_rptr_in;
            wq2_rptr <= wq1_rptr;
        end
    end
endmodule

// 3. 2-Flip-Flop Synchronizer (Read to Write Domain)
module sync_r2w #(
    parameter ADDRSIZE = 4
)(
    input  wire                wclk, wrst_n,
    input  wire [ADDRSIZE:0]   rq2_wptr_in,
    output reg  [ADDRSIZE:0]   rq2_wptr
);
    reg [ADDRSIZE:0] rq1_wptr;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            rq1_wptr <= 0;
            rq2_wptr <= 0;
        end else begin
            rq1_wptr <= rq2_wptr_in;
            rq2_wptr <= rq1_wptr;
        end
    end
endmodule

// 4. Read Pointer & Empty Flag Generator
module rptr_empty #(
    parameter ADDRSIZE = 4
)(
    input  wire                rclk, rrst_n, rinc,
    input  wire [ADDRSIZE:0]   rq2_wptr,
    output reg                 rempty,
    output wire [ADDRSIZE-1:0] raddr,
    output reg  [ADDRSIZE:0]   rptr
);
    reg  [ADDRSIZE:0] rbin;
    wire [ADDRSIZE:0] rbin_next, rgray_next;
    wire              rempty_val;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin <= 0;
            rptr <= 0;
        end else begin
            rbin <= rbin_next;
            rptr <= rgray_next;
        end
    end

    assign rbin_next  = rbin + (rinc & ~rempty);
    assign rgray_next = (rbin_next >> 1) ^ rbin_next;
    assign raddr      = rbin[ADDRSIZE-1:0];

    // Empty condition: Read pointer equals synchronized Write pointer
    assign rempty_val = (rgray_next == rq2_wptr);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) rempty <= 1'b1;
        else         rempty <= rempty_val;
    end
endmodule

// 5. Write Pointer & Full Flag Generator
module wptr_full #(
    parameter ADDRSIZE = 4
)(
    input  wire                wclk, wrst_n, winc,
    input  wire [ADDRSIZE:0]   wq2_rptr,
    output reg                 wfull,
    output wire [ADDRSIZE-1:0] waddr,
    output reg  [ADDRSIZE:0]   wptr
);
    reg  [ADDRSIZE:0] wbin;
    wire [ADDRSIZE:0] wbin_next, wgray_next;
    wire              wfull_val;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin <= 0;
            wptr <= 0;
        end else begin
            wbin <= wbin_next;
            wptr <= wgray_next;
        end
    end

    assign wbin_next  = wbin + (winc & ~wfull);
    assign wgray_next = (wbin_next >> 1) ^ wbin_next;
    assign waddr      = wbin[ADDRSIZE-1:0];

    // Full condition: MSB inverted, second MSB inverted, lower bits match
    assign wfull_val  = (wgray_next == {~wq2_rptr[ADDRSIZE:ADDRSIZE-1], wq2_rptr[ADDRSIZE-2:0]});

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) wfull <= 1'b0;
        else         wfull <= wfull_val;
    end
endmodule

// 6. Top-Level Asynchronous FIFO Module
module async_fifo #(
    parameter DSIZE = 8,
    parameter ASIZE = 4
)(
    input  wire             wclk, wrst_n, winc,
    input  wire [DSIZE-1:0] wdata,
    output wire             wfull,
    input  wire             rclk, rrst_n, rinc,
    output wire [DSIZE-1:0] rdata,
    output wire             rempty
);
    wire [ASIZE-1:0] waddr, raddr;
    wire [ASIZE:0]   wptr, rptr, wq2_rptr, rq2_wptr;

    sync_r2w #(.ADDRSIZE(ASIZE)) sync_r2w_inst (
        .wclk(wclk), .wrst_n(wrst_n), .rq2_wptr_in(rptr), .rq2_wptr(rq2_wptr)
    );

    sync_w2r #(.ADDRSIZE(ASIZE)) sync_w2r_inst (
        .rclk(rclk), .rrst_n(rrst_n), .wq2_rptr_in(wptr), .wq2_rptr(wq2_rptr)
    );

    fifomem #(.DATASIZE(DSIZE), .ADDRSIZE(ASIZE)) fifomem_inst (
        .winc(winc), .wfull(wfull), .wclk(wclk),
        .waddr(waddr), .raddr(raddr), .wdata(wdata), .rdata(rdata)
    );

    rptr_empty #(.ADDRSIZE(ASIZE)) rptr_empty_inst (
        .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc),
        .rq2_wptr(rq2_wptr), .rempty(rempty), .raddr(raddr), .rptr(rptr)
    );

    wptr_full #(.ADDRSIZE(ASIZE)) wptr_full_inst (
        .wclk(wclk), .wrst_n(wrst_n), .winc(winc),
        .wq2_rptr(wq2_rptr), .wfull(wfull), .waddr(waddr), .wptr(wptr)
    );
endmodule