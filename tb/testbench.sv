`timescale 1ns/1ps

module tb_async_fifo;
    parameter DSIZE = 8;
    parameter ASIZE = 4; // Depth = 16

    reg             wclk, wrst_n, winc;
    reg [DSIZE-1:0] wdata;
    wire            wfull;

    reg             rclk, rrst_n, rinc;
    wire [DSIZE-1:0] rdata;
    wire            rempty;

    // Instantiate DUT
    async_fifo #(.DSIZE(DSIZE), .ASIZE(ASIZE)) dut (
        .wclk(wclk), .wrst_n(wrst_n), .winc(winc), .wdata(wdata), .wfull(wfull),
        .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc), .rdata(rdata), .rempty(rempty)
    );

    // Independent Asynchronous Clock Generators
    // Write clock: 100 MHz (Period = 10ns)
    initial wclk = 0;
    always #5 wclk = ~wclk;

    // Read clock: ~71.4 MHz (Period = 14ns)
    initial rclk = 0;
    always #7 rclk = ~rclk;

    // EPWave Dump Configuration
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_async_fifo);
    end

    // Verification Stimulus
    integer i;
    initial begin
        // Reset sequence
        wrst_n = 0; rrst_n = 0;
        winc   = 0; rinc   = 0;
        wdata  = 0;
        #30;
        wrst_n = 1; rrst_n = 1;
        #20;

        // Step 1: Burst Write until FIFO is FULL (Depth = 16)
        $display("[TIME: %0t] Starting burst write to fill FIFO...", $time);
        for (i = 1; i <= 16; i = i + 1) begin
            @(posedge wclk);
            winc  <= 1'b1;
            wdata <= i;
        end
        @(posedge wclk);
        winc <= 1'b0;

        // Step 2: Test overflow corner case
        #20;
        @(posedge wclk);
        winc  <= 1'b1;
        wdata <= 8'hFF; // Should not overwrite
        @(posedge wclk);
        winc  <= 1'b0;

        // Step 3: Burst Read until FIFO is EMPTY
        #50;
        $display("[TIME: %0t] Starting burst read to empty FIFO...", $time);
        for (i = 1; i <= 16; i = i + 1) begin
            @(posedge rclk);
            rinc <= 1'b1;
        end
        @(posedge rclk);
        rinc <= 1'b0;

        // Step 4: Test underflow corner case
        #30;
        @(posedge rclk);
        rinc <= 1'b1; // Read on empty
        @(posedge rclk);
        rinc <= 1'b0;

        // Step 5: Simultaneous Read and Write across clock boundaries
        #50;
        $display("[TIME: %0t] Starting concurrent Read and Write transactions...", $time);
        fork
            begin
                for (i = 100; i < 110; i = i + 1) begin
                    @(posedge wclk);
                    winc  <= 1'b1;
                    wdata <= i;
                end
                @(posedge wclk);
                winc <= 1'b0;
            end
            begin
                for (i = 0; i < 10; i = i + 1) begin
                    @(posedge rclk);
                    rinc <= 1'b1;
                end
                @(posedge rclk);
                rinc <= 1'b0;
            end
        join

        #100;
        $display("[TIME: %0t] Simulation finished successfully.", $time);
        $finish;
    end
endmodule