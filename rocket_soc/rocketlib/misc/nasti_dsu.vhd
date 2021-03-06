-----------------------------------------------------------------------------
--! @file
--! @copyright Copyright 2015 GNSS Sensor Ltd. All right reserved.
--! @author    Sergey Khabarov - sergeykhbr@gmail.com
--! @brief     Implementation of nasti_dsu (Debug Support Unit).
--! @details   DSU provides access to the internal CPU registers (CSRs) via
--!            'Rocket-chip' specific bus HostIO.
-----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library commonlib;
use commonlib.types_common.all;
--! AMBA system bus specific library.
library ambalib;
--! AXI4 configuration constants.
use ambalib.types_amba4.all;
--! RISCV specific funcionality.
library rocketlib;
use rocketlib.types_rocket.all;

entity nasti_dsu is
  generic (
    xindex   : integer := 0;
    xaddr    : integer := 0;
    xmask    : integer := 16#fffff#;
    htif_index  : integer := 0
  );
  port 
  (
    clk    : in std_logic;
    nrst   : in std_logic;
    o_cfg  : out nasti_slave_config_type;
    i_axi  : in nasti_slave_in_type;
    o_axi  : out nasti_slave_out_type;
    i_host : in host_in_type;
    o_host : out host_out_type
  );
end;

architecture arch_nasti_dsu of nasti_dsu is

  constant xconfig : nasti_slave_config_type := (
     xindex => xindex,
     xaddr => conv_std_logic_vector(xaddr, CFG_NASTI_CFG_ADDR_BITS),
     xmask => conv_std_logic_vector(xmask, CFG_NASTI_CFG_ADDR_BITS),
     vid => VENDOR_GNSSSENSOR,
     did => GNSSSENSOR_DSU,
     descrtype => PNP_CFG_TYPE_SLAVE,
     descrsize => PNP_CFG_SLAVE_DESCR_BYTES
  );

type state_type is (wait_grant, writting, wait_resp, skip1);

type registers is record
  bank_axi : nasti_slave_bank_type;
  --! Message multiplexer to form 128 request message of writting into CSR
  state         : state_type;
  waddr : std_logic_vector(11 downto 0);
  wdata : std_logic_vector(63 downto 0);
  rdata : std_logic_vector(63 downto 0);
end record;

signal r, rin: registers;
begin

  comblogic : process(i_axi, i_host, r)
    variable v : registers;
    variable rdata : std_logic_vector(CFG_NASTI_DATA_BITS-1 downto 0);

    variable vhost : host_out_type;
  begin
    v := r;
    vhost := host_out_none;

    procedureAxi4(i_axi, xconfig, r.bank_axi, v.bank_axi);
    --! redefine value 'always ready' inserting waiting states.
    v.bank_axi.rwaitready := '0';

    if r.bank_axi.wstate = wtrans then
      -- Write data on next clock.
      v.waddr := r.bank_axi.raddr(0)(15 downto 4);
      if i_axi.w_strb(7 downto 0) /= X"00" then
          v.wdata := i_axi.w_data(63 downto 0);
      else
          v.wdata := i_axi.w_data(127 downto 64);
      end if;
      v.state := writting;
    end if;

    case r.state is
      when wait_grant =>
           vhost.csr_req_bits_addr := r.bank_axi.raddr(0)(15 downto 4);
           if r.bank_axi.rstate = rtrans then
               vhost.csr_req_valid     := '1';
               if (i_host.grant(htif_index) and i_host.csr_req_ready) = '1' then
                   v.state := wait_resp;
               end if;
           end if;
      when writting =>
           vhost.csr_req_valid     := '1';
           vhost.csr_req_bits_rw   := '1';
           vhost.csr_req_bits_addr := r.waddr;
           vhost.csr_req_bits_data := r.wdata;
           if (i_host.grant(htif_index) and i_host.csr_req_ready) = '1' then
               v.state := wait_resp;
           end if;
      when wait_resp =>
           vhost.csr_resp_ready := '1';
           if i_host.csr_resp_valid = '1' then
               v.state := skip1;
               v.rdata := i_host.csr_resp_bits;
               v.bank_axi.rwaitready := '1';
           end if;
      when skip1 =>
           v.state := wait_grant;
      when others =>
    end case;

    rdata := r.rdata & r.rdata;

    o_axi <= functionAxi4Output(r.bank_axi, rdata);
    o_host <= vhost;

    rin <= v;
  end process;

  o_cfg  <= xconfig;


  -- registers:
  regs : process(clk, nrst)
  begin 
    if nrst = '0' then 
       r.bank_axi <= NASTI_SLAVE_BANK_RESET;
       r.state <= wait_grant;
       r.waddr <= (others => '0');
       r.wdata <= (others => '0');
       r.rdata <= (others => '0');
    elsif rising_edge(clk) then 
       r <= rin; 
    end if; 
  end process;
end;
