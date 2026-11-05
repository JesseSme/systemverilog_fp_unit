-- Copyright 2026 Jesse Smedberg
-- SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

-- VHDL top of the AXI4-Stream floating-point unit (jsm_fp_unit_axis).
--
-- VHDL-93, std_logic ports and integer generics; instantiates the Verilog
-- top jsm_fp_unit_axis_top (rtl/top/jsm_fp_unit_axis_top.v), which has the
-- TDATA layouts and parameter descriptions. See docs/user_guide.md.
-- TDATA widths: S_AXIS 3*OPB + 8, M_AXIS OPB + 8 bits, with OPB the format
-- width 1 + W_EXP + W_MANT rounded up to a multiple of 8.

library ieee;
use ieee.std_logic_1164.all;

entity jsm_fp_unit_axis_vhd is
  generic (
    W_EXP        : integer := 8;
    W_MANT       : integer := 23;
    DIVSQRT_IMPL : integer := 1;
    OPS_EN       : integer := 65535;
    TUSER_W      : integer := 1;
    DEPTH        : integer := 0
  );
  port (
    aclk          : in  std_logic;
    aresetn       : in  std_logic;
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;
    s_axis_tdata  : in  std_logic_vector(3 * (((W_EXP + W_MANT + 8) / 8) * 8) + 7 downto 0);
    s_axis_tuser  : in  std_logic_vector(TUSER_W - 1 downto 0);
    s_axis_tlast  : in  std_logic;
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tdata  : out std_logic_vector((((W_EXP + W_MANT + 8) / 8) * 8) + 7 downto 0);
    m_axis_tuser  : out std_logic_vector(TUSER_W - 1 downto 0);
    m_axis_tlast  : out std_logic
  );
end entity jsm_fp_unit_axis_vhd;

architecture wrapper of jsm_fp_unit_axis_vhd is

  -- Vivado interface attributes (IP integrator infers the clock, reset and
  -- bus interfaces from them). Vivado reads them only here, in the
  -- architecture, although VHDL puts port attribute specifications in the
  -- entity: strict tools need a relaxed mode for this file (GHDL:
  -- -frelaxed), and can also simply ignore the attributes.
  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of aclk : signal is "xilinx.com:signal:clock:1.0 aclk CLK";
  attribute X_INTERFACE_PARAMETER of aclk : signal is
    "ASSOCIATED_BUSIF S_AXIS:M_AXIS, ASSOCIATED_RESET aresetn";
  attribute X_INTERFACE_INFO of aresetn : signal is "xilinx.com:signal:reset:1.0 aresetn RST";
  attribute X_INTERFACE_PARAMETER of aresetn : signal is "POLARITY ACTIVE_LOW";
  attribute X_INTERFACE_INFO of s_axis_tvalid : signal is "xilinx.com:interface:axis:1.0 S_AXIS TVALID";
  attribute X_INTERFACE_INFO of s_axis_tready : signal is "xilinx.com:interface:axis:1.0 S_AXIS TREADY";
  attribute X_INTERFACE_INFO of s_axis_tdata  : signal is "xilinx.com:interface:axis:1.0 S_AXIS TDATA";
  attribute X_INTERFACE_INFO of s_axis_tuser  : signal is "xilinx.com:interface:axis:1.0 S_AXIS TUSER";
  attribute X_INTERFACE_INFO of s_axis_tlast  : signal is "xilinx.com:interface:axis:1.0 S_AXIS TLAST";
  attribute X_INTERFACE_INFO of m_axis_tvalid : signal is "xilinx.com:interface:axis:1.0 M_AXIS TVALID";
  attribute X_INTERFACE_INFO of m_axis_tready : signal is "xilinx.com:interface:axis:1.0 M_AXIS TREADY";
  attribute X_INTERFACE_INFO of m_axis_tdata  : signal is "xilinx.com:interface:axis:1.0 M_AXIS TDATA";
  attribute X_INTERFACE_INFO of m_axis_tuser  : signal is "xilinx.com:interface:axis:1.0 M_AXIS TUSER";
  attribute X_INTERFACE_INFO of m_axis_tlast  : signal is "xilinx.com:interface:axis:1.0 M_AXIS TLAST";

  component jsm_fp_unit_axis_top is
    generic (
      W_EXP        : integer;
      W_MANT       : integer;
      DIVSQRT_IMPL : integer;
      OPS_EN       : integer;
      TUSER_W      : integer;
      DEPTH        : integer
    );
    port (
      aclk          : in  std_logic;
      aresetn       : in  std_logic;
      s_axis_tvalid : in  std_logic;
      s_axis_tready : out std_logic;
      s_axis_tdata  : in  std_logic_vector(3 * (((W_EXP + W_MANT + 8) / 8) * 8) + 7 downto 0);
      s_axis_tuser  : in  std_logic_vector(TUSER_W - 1 downto 0);
      s_axis_tlast  : in  std_logic;
      m_axis_tvalid : out std_logic;
      m_axis_tready : in  std_logic;
      m_axis_tdata  : out std_logic_vector((((W_EXP + W_MANT + 8) / 8) * 8) + 7 downto 0);
      m_axis_tuser  : out std_logic_vector(TUSER_W - 1 downto 0);
      m_axis_tlast  : out std_logic
    );
  end component jsm_fp_unit_axis_top;

begin

  u_fp_unit_axis_top : jsm_fp_unit_axis_top
    generic map (
      W_EXP        => W_EXP,
      W_MANT       => W_MANT,
      DIVSQRT_IMPL => DIVSQRT_IMPL,
      OPS_EN       => OPS_EN,
      TUSER_W      => TUSER_W,
      DEPTH        => DEPTH
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tuser  => s_axis_tuser,
      s_axis_tlast  => s_axis_tlast,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tuser  => m_axis_tuser,
      m_axis_tlast  => m_axis_tlast
    );

end architecture wrapper;
