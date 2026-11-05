-- Copyright 2026 Jesse Smedberg
-- SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

-- VHDL top-level wrapper of the floating-point unit (jsm_fp_unit).
--
-- VHDL-93, std_logic ports and integer generics. It instantiates the
-- Verilog-2001 wrapper jsm_fp_unit_top (rtl/top/jsm_fp_unit_top.v) as a component,
-- which in turn instantiates the SystemVerilog core through
-- rtl/top/jsm_fp_unit_flat.sv. Add all of them to the project (rtl/filelist.f,
-- jsm_fp_unit_flat.sv, jsm_fp_unit_top.v and this file); Vivado synthesis and xsim
-- handle the language mix.
--
-- Interface and generics: see jsm_fp_unit_top.v and docs/user_guide.md.
--   * A request is accepted on a rising clk edge with in_valid = '1' and
--     in_ready = '1'; hold mode/rm/a/b/c/in_tag stable while in_valid = '1'
--     and in_ready = '0'.
--   * Each accepted request gives one out_valid pulse after the operation's
--     fixed latency, with out_tag = its in_tag (results can complete out of
--     request order).
--   * rst_n is synchronous and active low.

library ieee;
use ieee.std_logic_1164.all;

entity jsm_fp_unit_vhd is
  generic (
    W_EXP        : integer := 8;      -- exponent bits
    W_MANT       : integer := 23;     -- fraction bits
    DIVSQRT_IMPL : integer := 1;      -- 1 SRT, 3 SRT 4.0 ns form, 2 iterative, 0 comb.
    TAG_W        : integer := 1;      -- request tag width (>= 1)
    OPS_EN       : integer := 65535   -- operation enable mask, bit i = opcode i
  );
  port (
    clk       : in  std_logic;
    rst_n     : in  std_logic;
    in_valid  : in  std_logic;
    in_ready  : out std_logic;
    mode      : in  std_logic_vector(3 downto 0);                -- opcode
    rm        : in  std_logic_vector(2 downto 0);                -- rounding mode
    a         : in  std_logic_vector(W_EXP + W_MANT downto 0);
    b         : in  std_logic_vector(W_EXP + W_MANT downto 0);
    c         : in  std_logic_vector(W_EXP + W_MANT downto 0);  -- FMA addend
    in_tag    : in  std_logic_vector(TAG_W - 1 downto 0);
    y         : out std_logic_vector(W_EXP + W_MANT downto 0);
    cmp       : out std_logic_vector(1 downto 0);
    flags     : out std_logic_vector(4 downto 0);  -- invalid, div0, overflow, underflow, inexact
    out_valid : out std_logic;
    out_tag   : out std_logic_vector(TAG_W - 1 downto 0)
  );
end entity jsm_fp_unit_vhd;

architecture wrapper of jsm_fp_unit_vhd is

  -- Vivado interface attributes (IP integrator infers the clock, reset and
  -- bus interfaces from them). Vivado reads them only here, in the
  -- architecture, although VHDL puts port attribute specifications in the
  -- entity: strict tools need a relaxed mode for this file (GHDL:
  -- -frelaxed), and can also simply ignore the attributes.
  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of clk : signal is "xilinx.com:signal:clock:1.0 clk CLK";
  attribute X_INTERFACE_PARAMETER of clk : signal is "ASSOCIATED_RESET rst_n";
  attribute X_INTERFACE_INFO of rst_n : signal is "xilinx.com:signal:reset:1.0 rst_n RST";
  attribute X_INTERFACE_PARAMETER of rst_n : signal is "POLARITY ACTIVE_LOW";

  component jsm_fp_unit_top is
    generic (
      W_EXP        : integer;
      W_MANT       : integer;
      DIVSQRT_IMPL : integer;
      TAG_W        : integer;
      OPS_EN       : integer
    );
    port (
      clk       : in  std_logic;
      rst_n     : in  std_logic;
      in_valid  : in  std_logic;
      in_ready  : out std_logic;
      mode      : in  std_logic_vector(3 downto 0);
      rm        : in  std_logic_vector(2 downto 0);
      a         : in  std_logic_vector(W_EXP + W_MANT downto 0);
      b         : in  std_logic_vector(W_EXP + W_MANT downto 0);
      c         : in  std_logic_vector(W_EXP + W_MANT downto 0);
      in_tag    : in  std_logic_vector(TAG_W - 1 downto 0);
      y         : out std_logic_vector(W_EXP + W_MANT downto 0);
      cmp       : out std_logic_vector(1 downto 0);
      flags     : out std_logic_vector(4 downto 0);
      out_valid : out std_logic;
      out_tag   : out std_logic_vector(TAG_W - 1 downto 0)
    );
  end component jsm_fp_unit_top;

begin

  u_fp_unit_top : jsm_fp_unit_top
    generic map (
      W_EXP        => W_EXP,
      W_MANT       => W_MANT,
      DIVSQRT_IMPL => DIVSQRT_IMPL,
      TAG_W        => TAG_W,
      OPS_EN       => OPS_EN
    )
    port map (
      clk       => clk,
      rst_n     => rst_n,
      in_valid  => in_valid,
      in_ready  => in_ready,
      mode      => mode,
      rm        => rm,
      a         => a,
      b         => b,
      c         => c,
      in_tag    => in_tag,
      y         => y,
      cmp       => cmp,
      flags     => flags,
      out_valid => out_valid,
      out_tag   => out_tag
    );

end architecture wrapper;
