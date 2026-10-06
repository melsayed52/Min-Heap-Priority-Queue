// ram_dp.v - inferable simple-dual-port RAM, synchronous read, registered output.
// One write port, one read port, common clock. Read is "read-first" with
// respect to a same-edge write to the same address (Verilog nonblocking
// semantics); consumers compensate with the per-level write-history bypass.
// Maps to block RAM in Vivado (registered-output style) with no primitives.
`default_nettype none

module ram_dp #(
  parameter AW = 8,
  parameter DW = 48
)(
  input  wire          clk,
  input  wire          we,
  input  wire [AW-1:0] waddr,
  input  wire [DW-1:0] wdata,
  input  wire [AW-1:0] raddr,
  output reg  [DW-1:0] dout2   // valid 2 cycles after raddr is presented
);

  reg [DW-1:0] mem [0:(1<<AW)-1];
  reg [DW-1:0] dout_r;

  always @(posedge clk) begin
    if (we)
      mem[waddr] <= wdata;
    dout_r <= mem[raddr];
    dout2  <= dout_r;
  end

endmodule

`default_nettype wire
