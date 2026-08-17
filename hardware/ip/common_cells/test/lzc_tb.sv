// Wraps cc_lzc so there is a concrete top module to verilate.
//
// A library cell is not a design: cc_lzc is parameterised and has no fixed
// width until something instantiates it. This fixes Width and instantiates both
// counting modes side by side, so one verilated model exercises both.
module lzc_tb #(
  parameter int unsigned Width = 8
) (
  input  logic [Width-1:0]                        in_i,
  output logic [cc_pkg::idx_width(Width)-1:0]     trailing_cnt_o,
  output logic                                    trailing_empty_o,
  output logic [cc_pkg::idx_width(Width)-1:0]     leading_cnt_o,
  output logic                                    leading_empty_o
);

  // Counts zeros from the LSB: the index of the lowest set bit.
  cc_lzc #(
    .Width (Width),
    .Mode  (cc_pkg::LZC_TRAILING_ZERO_CNT)
  ) i_trailing (
    .in_i    (in_i),
    .cnt_o   (trailing_cnt_o),
    .empty_o (trailing_empty_o)
  );

  // Counts zeros from the MSB: Width-1 minus the index of the highest set bit.
  cc_lzc #(
    .Width (Width),
    .Mode  (cc_pkg::LZC_LEADING_ZERO_CNT)
  ) i_leading (
    .in_i    (in_i),
    .cnt_o   (leading_cnt_o),
    .empty_o (leading_empty_o)
  );

endmodule
