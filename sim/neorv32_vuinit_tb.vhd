-- ================================================================================ --
-- NEORV32 - VUnit Processor Testbench                                              --
-- -------------------------------------------------------------------------------- --
-- The NEORV32 RISC-V Processor - https://github.com/stnolting/neorv32              --
-- Copyright (c) NEORV32 contributors.                                              --
-- Copyright (c) 2020 - 2024 Stephan Nolting. All rights reserved.                  --
-- Licensed under the BSD-3-Clause license, see LICENSE for details.                --
-- SPDX-License-Identifier: BSD-3-Clause                                            --
-- ================================================================================ --

library vunit_lib;
context vunit_lib.vunit_context;
context vunit_lib.com_context;
context vunit_lib.vc_context;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library neorv32;
use neorv32.neorv32_package.all;
use neorv32.neorv32_application_image.all; -- this file is generated by the image generator

use std.textio.all;

library osvvm;
use osvvm.RandomPkg.all;

use work.uart_rx_pkg.all;

entity neorv32_vunit_tb is
  generic (runner_cfg : string := runner_cfg_default;
           ci_mode : boolean := false);
end neorv32_vunit_tb;

architecture neorv32_vunit_tb_rtl of neorv32_vunit_tb is

  -- User Configuration ---------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- general --
  constant imem_size_c             : natural := 32*1024; -- size in bytes of processor-internal IMEM / external mem A
  constant dmem_size_c             : natural := 8*1024; -- size in bytes of processor-internal DMEM / external mem B
  constant f_clock_c               : natural := 100000000; -- main clock in Hz
  constant baud0_rate_c            : natural := 19200; -- simulation UART0 (primary UART) baud rate
  constant baud1_rate_c            : natural := 19200; -- simulation UART1 (secondary UART) baud rate
  constant icache_en_c             : boolean := false; -- implement i-cache
  constant icache_block_size_c     : natural := 64; -- i-cache block size in bytes
  -- simulated external Wishbone memory A (can be used as external IMEM) --
  constant ext_mem_a_base_addr_c   : std_ulogic_vector(31 downto 0) := x"00000000"; -- wishbone memory base address (external IMEM base)
  constant ext_mem_a_size_c        : natural := imem_size_c; -- wishbone memory size in bytes
  constant ext_mem_a_latency_c     : natural := 8; -- latency in clock cycles (min 1, max 255), plus 1 cycle initial delay
  -- simulated external Wishbone memory B (can be used as external DMEM) --
  constant ext_mem_b_base_addr_c   : std_ulogic_vector(31 downto 0) := x"80000000"; -- wishbone memory base address (external DMEM base)
  constant ext_mem_b_size_c        : natural := dmem_size_c; -- wishbone memory size in bytes
  constant ext_mem_b_latency_c     : natural := 8; -- latency in clock cycles (min 1, max 255), plus 1 cycle initial delay
  -- simulated external Wishbone memory C (can be used to simulate external IO access) --
  constant ext_mem_c_base_addr_c   : std_ulogic_vector(31 downto 0) := x"F0000000"; -- wishbone memory base address (default begin of EXTERNAL IO area)
  constant ext_mem_c_size_c        : natural := icache_block_size_c/2; -- wishbone memory size in bytes, should be smaller than an iCACHE block
  constant ext_mem_c_latency_c     : natural := 128; -- latency in clock cycles (min 1, max 255), plus 1 cycle initial delay
  -- simulation interrupt trigger --
  constant irq_trigger_base_addr_c : std_ulogic_vector(31 downto 0) := x"FF000000";
  -- -------------------------------------------------------------------------------------------

  -- internals - hands off! --
  constant uart0_baud_val_c : real := real(f_clock_c) / real(baud0_rate_c);
  constant uart1_baud_val_c : real := real(f_clock_c) / real(baud1_rate_c);
  constant t_clock_c        : time := (1 sec) / f_clock_c;

  -- generators --
  signal clk_gen, rst_gen : std_ulogic := '0';

  -- uart --
  signal uart0_txd, uart1_txd : std_ulogic;
  signal uart0_cts, uart1_cts : std_ulogic;

  -- gpio --
  signal gpio : std_ulogic_vector(63 downto 0);

  -- twi --
  signal twi_scl, twi_sda : std_logic;
  signal twi_scl_i, twi_scl_o, twi_sda_i, twi_sda_o : std_ulogic;
  signal twd_scl_i, twd_scl_o, twd_sda_i, twd_sda_o : std_ulogic;

  -- 1-wire --
  signal onewire : std_logic;
  signal onewire_i, onewire_o : std_ulogic;

  -- spi & sdi --
  signal spi_csn: std_ulogic_vector(7 downto 0);
  signal spi_di, spi_do, spi_clk : std_ulogic;
  signal sdi_di, sdi_do, sdi_clk, sdi_csn : std_ulogic;

  -- irq --
  signal msi_ring, mei_ring : std_ulogic;

  -- SLINK echo --
  signal slink_dat : std_ulogic_vector(31 downto 0);
  signal slink_val : std_ulogic;
  signal slink_lst : std_ulogic;
  signal slink_rdy : std_ulogic;
  signal slink_id  : std_ulogic_vector(3 downto 0);

  -- Wishbone bus --
  type wishbone_t is record
    addr  : std_ulogic_vector(31 downto 0); -- address
    wdata : std_ulogic_vector(31 downto 0); -- master write data
    rdata : std_ulogic_vector(31 downto 0); -- master read data
    tag   : std_ulogic_vector(2 downto 0); -- access tag
    we    : std_ulogic; -- write enable
    sel   : std_ulogic_vector(3 downto 0); -- byte enable
    stb   : std_ulogic; -- strobe
    cyc   : std_ulogic; -- valid cycle
    ack   : std_ulogic; -- transfer acknowledge
    err   : std_ulogic; -- transfer error
  end record;
  signal wb_cpu, wb_mem_a, wb_mem_b, wb_mem_c, wb_irq : wishbone_t;

  -- Wishbone access latency type --
  type ext_mem_read_latency_t is array (0 to 255) of std_ulogic_vector(31 downto 0);

  -- simulated external memory c (IO) --
  signal ext_ram_c : mem32_t(0 to ext_mem_c_size_c/4-1); -- uninitialized, used to simulate external IO

  -- simulated external memory bus feedback type --
  type ext_mem_t is record
    rdata  : ext_mem_read_latency_t;
    acc_en : std_ulogic;
    ack    : std_ulogic_vector(255 downto 0);
  end record;
  signal ext_mem_a, ext_mem_b, ext_mem_c : ext_mem_t;

  constant uart0_rx_logger : logger_t := get_logger("UART0.RX");
  constant uart1_rx_logger : logger_t := get_logger("UART1.RX");
  constant uart0_rx_handle : uart_rx_t := new_uart_rx(uart0_baud_val_c, uart0_rx_logger);
  constant uart1_rx_handle : uart_rx_t := new_uart_rx(uart1_baud_val_c, uart1_rx_logger);

begin
  test_runner : process
    variable msg : msg_t;
    variable rnd : RandomPType;
  begin
    test_runner_setup(runner, runner_cfg);

    rnd.InitSeed(test_runner'path_name);

    -- Show passing checks for UART0 on the display (stdout)
    show(uart0_rx_logger, display_handler, pass);
    show(uart1_rx_logger, display_handler, pass);

    if ci_mode then
      check_uart(net, uart0_rx_handle, nul & nul);
    else
      check_uart(net, uart0_rx_handle, "Blinking LED demo program" & cr & lf);
    end if;

    if ci_mode then
      -- No need to send the full expectation in one big chunk
      check_uart(net, uart1_rx_handle, nul & nul);
      check_uart(net, uart1_rx_handle, "0/55" & cr & lf);
    end if;

    -- Wait until all expected data has been received
    --
    -- wait_until_idle can take the VC actor as argument but
    -- the more abstract view is that wait_until_idle is part
    -- of the sync VCI and to use it a VC must be cast
    -- to a sync VC
    wait_until_idle(net, as_sync(uart0_rx_handle));
    wait_until_idle(net, as_sync(uart1_rx_handle));

    -- Wait a bit more if some extra unexpected data is produced. If so,
    -- uart_rx will fail
    wait for (20 * (1e9 / baud0_rate_c)) * ns;

    test_runner_cleanup(runner);
  end process;

  -- In case we get stuck waiting there is a watchdog timeout to terminate and fail the
  -- testbench
  test_runner_watchdog(runner, 50 ms);

  -- Clock/Reset Generator ------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  clk_gen <= not clk_gen after (t_clock_c/2);
  rst_gen <= '0', '1' after 60*(t_clock_c/2);


  -- The Core of the Problem ----------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  neorv32_top_inst: neorv32_top
  generic map (
    -- Processor Clocking --
    CLOCK_FREQUENCY       => f_clock_c,
    -- Identification --
    HART_ID               => x"00000000",
    JEDEC_ID              => "00000000000",
    -- Boot Configuration --
    BOOT_MODE_SELECT      => 1,
    BOOT_ADDR_CUSTOM      => x"00000000",
    -- On-Chip Debugger (OCD) --
    OCD_EN                => true,
    OCD_AUTHENTICATION    => true,
    -- RISC-V CPU Extensions --
    RISCV_ISA_C           => true,
    RISCV_ISA_E           => false,
    RISCV_ISA_M           => true,
    RISCV_ISA_U           => true,
    RISCV_ISA_Zalrsc      => true,
    RISCV_ISA_Zba         => true,
    RISCV_ISA_Zbb         => true,
    RISCV_ISA_Zbkb        => true,
    RISCV_ISA_Zbkc        => true,
    RISCV_ISA_Zbkx        => true,
    RISCV_ISA_Zbs         => true,
    RISCV_ISA_Zfinx       => true,
    RISCV_ISA_Zicntr      => true,
    RISCV_ISA_Zicond      => true,
    RISCV_ISA_Zihpm       => true,
    RISCV_ISA_Zknd        => true,
    RISCV_ISA_Zkne        => true,
    RISCV_ISA_Zknh        => true,
    RISCV_ISA_Zksed       => true,
    RISCV_ISA_Zksh        => true,
    RISCV_ISA_Zmmul       => false,
    RISCV_ISA_Zxcfu       => true,
    -- Extension Options --
    CPU_CLOCK_GATING_EN   => false,
    CPU_FAST_MUL_EN       => false,
    CPU_FAST_SHIFT_EN     => false,
    CPU_RF_HW_RST_EN      => true,
    -- Physical Memory Protection (PMP) --
    PMP_NUM_REGIONS       => 5,
    PMP_MIN_GRANULARITY   => 4,
    PMP_TOR_MODE_EN       => true,
    PMP_NAP_MODE_EN       => true,
    -- Hardware Performance Monitors (HPM) --
    HPM_NUM_CNTS          => 12,
    HPM_CNT_WIDTH         => 40,
    -- Internal Instruction memory --
    MEM_INT_IMEM_EN       => false,
    -- Internal Data memory --
    MEM_INT_DMEM_EN       => false,
    -- Internal Cache memory --
    ICACHE_EN             => false,
    -- Internal Data Cache (dCACHE) --
    DCACHE_EN             => false,
    -- External bus interface --
    XBUS_EN               => true,
    XBUS_TIMEOUT          => 256,
    XBUS_REGSTAGE_EN      => false,
    XBUS_CACHE_EN         => true,
    XBUS_CACHE_NUM_BLOCKS => 64,
    XBUS_CACHE_BLOCK_SIZE => 32,
    -- Execute in-place module (XIP) --
    XIP_EN                => true,
    XIP_CACHE_EN          => true,
    XIP_CACHE_NUM_BLOCKS  => 4,
    XIP_CACHE_BLOCK_SIZE  => 256,
    -- External Interrupts Controller (XIRQ) --
    XIRQ_NUM_CH           => 32,
    -- Processor peripherals --
    IO_GPIO_NUM           => 64,
    IO_MTIME_EN           => true,
    IO_UART0_EN           => true,
    IO_UART0_RX_FIFO      => 32,
    IO_UART0_TX_FIFO      => 32,
    IO_UART1_EN           => true,
    IO_UART1_RX_FIFO      => 1,
    IO_UART1_TX_FIFO      => 1,
    IO_SPI_EN             => true,
    IO_SPI_FIFO           => 4,
    IO_SDI_EN             => true,
    IO_SDI_FIFO           => 4,
    IO_TWI_EN             => true,
    IO_TWI_FIFO           => 4,
    IO_PWM_NUM_CH         => 8,
    IO_WDT_EN             => true,
    IO_TRNG_EN            => true,
    IO_TRNG_FIFO          => 4,
    IO_CFS_EN             => true,
    IO_CFS_CONFIG         => (others => '0'),
    IO_CFS_IN_SIZE        => 32,
    IO_CFS_OUT_SIZE       => 32,
    IO_NEOLED_EN          => true,
    IO_NEOLED_TX_FIFO     => 8,
    IO_GPTMR_EN           => true,
    IO_ONEWIRE_EN         => true,
    IO_DMA_EN             => true,
    IO_SLINK_EN           => true,
    IO_SLINK_RX_FIFO      => 4,
    IO_SLINK_TX_FIFO      => 4,
    IO_CRC_EN             => true
  )
  port map (
    -- Global control --
    clk_i          => clk_gen,
    rstn_i         => rst_gen,
    -- JTAG on-chip debugger interface (available if OCD_EN = true) --
    jtag_tck_i     => '0',
    jtag_tdi_i     => '0',
    jtag_tdo_o     => open,
    jtag_tms_i     => '0',
    -- External bus interface (available if XBUS_EN = true) --
    xbus_adr_o     => wb_cpu.addr,
    xbus_dat_o     => wb_cpu.wdata,
    xbus_tag_o     => wb_cpu.tag,
    xbus_we_o      => wb_cpu.we,
    xbus_sel_o     => wb_cpu.sel,
    xbus_stb_o     => wb_cpu.stb,
    xbus_cyc_o     => wb_cpu.cyc,
    xbus_dat_i     => wb_cpu.rdata,
    xbus_ack_i     => wb_cpu.ack,
    xbus_err_i     => wb_cpu.err,
    -- Stream Link Interface (available if IO_SLINK_EN = true) --
    slink_rx_dat_i => slink_dat,
    slink_rx_src_i => slink_id,
    slink_rx_val_i => slink_val,
    slink_rx_lst_i => slink_lst,
    slink_rx_rdy_o => slink_rdy,
    slink_tx_dat_o => slink_dat,
    slink_tx_dst_o => slink_id,
    slink_tx_val_o => slink_val,
    slink_tx_lst_o => slink_lst,
    slink_tx_rdy_i => slink_rdy,
    -- XIP (execute in place via SPI) signals (available if XIP_EN = true) --
    xip_csn_o      => open,
    xip_clk_o      => open,
    xip_dat_i      => '1',
    xip_dat_o      => open,
    -- GPIO (available if IO_GPIO_NUM > 0) --
    gpio_o         => gpio,
    gpio_i         => gpio,
    -- primary UART0 (available if IO_UART0_EN = true) --
    uart0_txd_o    => uart0_txd,
    uart0_rxd_i    => uart0_txd,
    uart0_rts_o    => uart1_cts,
    uart0_cts_i    => uart0_cts,
    -- secondary UART1 (available if IO_UART1_EN = true) --
    uart1_txd_o    => uart1_txd,
    uart1_rxd_i    => uart1_txd,
    uart1_rts_o    => uart0_cts,
    uart1_cts_i    => uart1_cts,
    -- SPI (available if IO_SPI_EN = true) --
    spi_clk_o      => spi_clk,
    spi_dat_o      => spi_do,
    spi_dat_i      => spi_di,
    spi_csn_o      => spi_csn,
    -- SDI (available if IO_SDI_EN = true) --
    sdi_clk_i      => sdi_clk,
    sdi_dat_o      => sdi_do,
    sdi_dat_i      => sdi_di,
    sdi_csn_i      => sdi_csn,
    -- TWI (available if IO_TWI_EN = true) --
    twi_sda_i      => twi_sda_i,
    twi_sda_o      => twi_sda_o,
    twi_scl_i      => twi_scl_i,
    twi_scl_o      => twi_scl_o,
    -- TWD --
    twd_sda_i      => twd_sda_i,
    twd_sda_o      => twd_sda_o,
    twd_scl_i      => twd_scl_i,
    twd_scl_o      => twd_scl_o,
    -- 1-Wire Interface (available if IO_ONEWIRE_EN = true) --
    onewire_i      => onewire_i,
    onewire_o      => onewire_o,
    -- PWM (available if IO_PWM_NUM_CH > 0) --
    pwm_o          => open,
    -- Custom Functions Subsystem IO --
    cfs_in_i       => (others => '0'),
    cfs_out_o      => open,
    -- NeoPixel-compatible smart LED interface (available if IO_NEOLED_EN = true) --
    neoled_o       => open,
    -- Machine timer system time (available if IO_MTIME_EN = true) --
    mtime_time_o   => open,
    -- External platform interrupts (available if XIRQ_NUM_CH > 0) --
    xirq_i         => gpio(31 downto 0),
    -- CPU Interrupts --
    mtime_irq_i    => '0',
    msw_irq_i      => msi_ring,
    mext_irq_i     => mei_ring
  );

  -- TWI tri-state driver --
  twi_sda   <= '0' when (twi_sda_o = '0') else 'Z'; -- module can only pull the line low actively
  twi_scl   <= '0' when (twi_scl_o = '0') else 'Z';
  twi_sda_i <= std_ulogic(twi_sda);
  twi_scl_i <= std_ulogic(twi_scl);

  i2c_sda   <= '0' when (twd_sda_o = '0') else 'Z';
  i2c_scl   <= '0' when (twd_scl_o = '0') else 'Z';
  twd_sda_i <= std_ulogic(i2c_sda); -- sense input
  twd_scl_i <= std_ulogic(i2c_scl); -- sense input

  -- TWI termination (pull-ups) --
  twi_scl <= 'H';
  twi_sda <= 'H';

  -- 1-Wire tri-state driver --
  onewire   <= '0' when (onewire_o = '0') else 'Z'; -- module can only pull the line low actively
  onewire_i <= std_ulogic(onewire);

  -- 1-Wire termination (pull-up) --
  onewire <= 'H';

  -- SPI/SDI echo with propagation delay --
  sdi_clk <= spi_clk after 40 ns;
  sdi_csn <= spi_csn(7) after 40 ns;
  sdi_di  <= spi_do after 40 ns;
  spi_di  <= sdi_do when (spi_csn(7) = '0') else spi_do after 40 ns;

  uart0_checker: entity work.uart_rx
    generic map (uart0_rx_handle)
    port map (
      clk => clk_gen,
      uart_txd => uart0_txd);

  uart1_checker: entity work.uart_rx
    generic map (uart1_rx_handle)
    port map (
      clk => clk_gen,
      uart_txd => uart1_txd);


  -- Wishbone Fabric ------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  -- CPU broadcast signals --
  wb_mem_a.addr  <= wb_cpu.addr;
  wb_mem_a.wdata <= wb_cpu.wdata;
  wb_mem_a.we    <= wb_cpu.we;
  wb_mem_a.sel   <= wb_cpu.sel;
  wb_mem_a.cyc   <= wb_cpu.cyc;

  wb_mem_b.addr  <= wb_cpu.addr;
  wb_mem_b.wdata <= wb_cpu.wdata;
  wb_mem_b.we    <= wb_cpu.we;
  wb_mem_b.sel   <= wb_cpu.sel;
  wb_mem_b.cyc   <= wb_cpu.cyc;

  wb_mem_c.addr  <= wb_cpu.addr;
  wb_mem_c.wdata <= wb_cpu.wdata;
  wb_mem_c.we    <= wb_cpu.we;
  wb_mem_c.sel   <= wb_cpu.sel;
  wb_mem_c.cyc   <= wb_cpu.cyc;

  wb_irq.addr    <= wb_cpu.addr;
  wb_irq.wdata   <= wb_cpu.wdata;
  wb_irq.we      <= wb_cpu.we;
  wb_irq.sel     <= wb_cpu.sel;
  wb_irq.cyc     <= wb_cpu.cyc;

  -- CPU read-back signals (no mux here since peripherals have "output gates") --
  wb_cpu.rdata <= wb_mem_a.rdata or wb_mem_b.rdata or wb_mem_c.rdata or wb_irq.rdata;
  wb_cpu.ack   <= wb_mem_a.ack   or wb_mem_b.ack   or wb_mem_c.ack   or wb_irq.ack;
  wb_cpu.err   <= wb_mem_a.err   or wb_mem_b.err   or wb_mem_c.err   or wb_irq.err;

  -- peripheral select via STROBE signal --
  wb_mem_a.stb <= wb_cpu.stb when (wb_cpu.addr >= ext_mem_a_base_addr_c) and (wb_cpu.addr < std_ulogic_vector(unsigned(ext_mem_a_base_addr_c) + ext_mem_a_size_c)) else '0';
  wb_mem_b.stb <= wb_cpu.stb when (wb_cpu.addr >= ext_mem_b_base_addr_c) and (wb_cpu.addr < std_ulogic_vector(unsigned(ext_mem_b_base_addr_c) + ext_mem_b_size_c)) else '0';
  wb_mem_c.stb <= wb_cpu.stb when (wb_cpu.addr >= ext_mem_c_base_addr_c) and (wb_cpu.addr < std_ulogic_vector(unsigned(ext_mem_c_base_addr_c) + ext_mem_c_size_c)) else '0';
  wb_irq.stb   <= wb_cpu.stb when (wb_cpu.addr =  irq_trigger_base_addr_c) else '0';


  -- Wishbone Memory A (simulated external IMEM) --------------------------------------------
  -- -------------------------------------------------------------------------------------------
  ext_mem_a_access: process(clk_gen)
    variable ext_ram_a : mem32_t(0 to ext_mem_a_size_c/4-1) := mem32_init_f(application_init_image, ext_mem_a_size_c/4); -- initialized, used to simulate external IMEM
  begin
    if rising_edge(clk_gen) then
      -- control --
      ext_mem_a.ack(0) <= wb_mem_a.cyc and wb_mem_a.stb; -- wishbone acknowledge

      -- write access --
      if ((wb_mem_a.cyc and wb_mem_a.stb and wb_mem_a.we) = '1') then -- valid write access
        for i in 0 to 3 loop
          if (wb_mem_a.sel(i) = '1') then
            ext_ram_a(to_integer(unsigned(wb_mem_a.addr(index_size_f(ext_mem_a_size_c/4)+1 downto 2))))(7+i*8 downto 0+i*8) := wb_mem_a.wdata(7+i*8 downto 0+i*8);
          end if;
        end loop; -- i
      end if;

      -- read access --
      ext_mem_a.rdata(0) <= ext_ram_a(to_integer(unsigned(wb_mem_a.addr(index_size_f(ext_mem_a_size_c/4)+1 downto 2)))); -- word aligned
      -- virtual read and ack latency --
      if (ext_mem_a_latency_c > 1) then
        for i in 1 to ext_mem_a_latency_c-1 loop
          ext_mem_a.rdata(i) <= ext_mem_a.rdata(i-1);
          ext_mem_a.ack(i)   <= ext_mem_a.ack(i-1) and wb_mem_a.cyc;
        end loop;
      end if;

      -- bus output register --
      wb_mem_a.err <= '0';
      if (ext_mem_a.ack(ext_mem_a_latency_c-1) = '1') and (wb_mem_a.cyc = '1') then
        wb_mem_a.rdata <= ext_mem_a.rdata(ext_mem_a_latency_c-1);
        wb_mem_a.ack   <= '1';
      else
        wb_mem_a.rdata <= (others => '0');
        wb_mem_a.ack   <= '0';
      end if;
    end if;
  end process ext_mem_a_access;


  -- Wishbone Memory B (simulated external DMEM) --------------------------------------------
  -- -------------------------------------------------------------------------------------------
  ext_mem_b_access: process(clk_gen)
    variable ext_ram_b : mem32_t(0 to ext_mem_b_size_c/4-1) := (others => (others => '0')); -- zero, used to simulate external DMEM
  begin
    if rising_edge(clk_gen) then
      -- control --
      ext_mem_b.ack(0) <= wb_mem_b.cyc and wb_mem_b.stb; -- wishbone acknowledge

      -- write access --
      if ((wb_mem_b.cyc and wb_mem_b.stb and wb_mem_b.we) = '1') then -- valid write access
        for i in 0 to 3 loop
          if (wb_mem_b.sel(i) = '1') then
            ext_ram_b(to_integer(unsigned(wb_mem_b.addr(index_size_f(ext_mem_b_size_c/4)+1 downto 2))))(7+i*8 downto 0+i*8) := wb_mem_b.wdata(7+i*8 downto 0+i*8);
          end if;
        end loop; -- i
      end if;

      -- read access --
      ext_mem_b.rdata(0) <= ext_ram_b(to_integer(unsigned(wb_mem_b.addr(index_size_f(ext_mem_b_size_c/4)+1 downto 2)))); -- word aligned
      -- virtual read and ack latency --
      if (ext_mem_b_latency_c > 1) then
        for i in 1 to ext_mem_b_latency_c-1 loop
          ext_mem_b.rdata(i) <= ext_mem_b.rdata(i-1);
          ext_mem_b.ack(i)   <= ext_mem_b.ack(i-1) and wb_mem_b.cyc;
        end loop;
      end if;

      -- bus output register --
      wb_mem_b.err <= '0';
      if (ext_mem_b.ack(ext_mem_b_latency_c-1) = '1') and (wb_mem_b.cyc = '1') then
        wb_mem_b.rdata <= ext_mem_b.rdata(ext_mem_b_latency_c-1);
        wb_mem_b.ack   <= '1';
      else
        wb_mem_b.rdata <= (others => '0');
        wb_mem_b.ack   <= '0';
      end if;
    end if;
  end process ext_mem_b_access;


  -- Wishbone Memory C (simulated external IO) ----------------------------------------------
  -- -------------------------------------------------------------------------------------------
  ext_mem_c_access: process(clk_gen)
  begin
    if rising_edge(clk_gen) then
      -- control --
      ext_mem_c.ack(0) <= wb_mem_c.cyc and wb_mem_c.stb; -- wishbone acknowledge

      -- write access --
      if ((wb_mem_c.cyc and wb_mem_c.stb and wb_mem_c.we) = '1') then -- valid write access
        for i in 0 to 3 loop
          if (wb_mem_c.sel(i) = '1') then
            ext_ram_c(to_integer(unsigned(wb_mem_c.addr(index_size_f(ext_mem_c_size_c/4)+1 downto 2))))(7+i*8 downto 0+i*8) <= wb_mem_c.wdata(7+i*8 downto 0+i*8);
          end if;
        end loop; -- i
      end if;

      -- read access --
      ext_mem_c.rdata(0) <= ext_ram_c(to_integer(unsigned(wb_mem_c.addr(index_size_f(ext_mem_c_size_c/4)+1 downto 2)))); -- word aligned
      -- virtual read and ack latency --
      if (ext_mem_c_latency_c > 1) then
        for i in 1 to ext_mem_c_latency_c-1 loop
          ext_mem_c.rdata(i) <= ext_mem_c.rdata(i-1);
          ext_mem_c.ack(i)   <= ext_mem_c.ack(i-1) and wb_mem_c.cyc;
        end loop;
      end if;

      -- bus output register --
      if (ext_mem_c.ack(ext_mem_c_latency_c-1) = '1') and (wb_mem_c.cyc = '1') then
        wb_mem_c.rdata <= ext_mem_c.rdata(ext_mem_c_latency_c-1);
        wb_mem_c.ack   <= '1';
        wb_mem_c.err   <= '0';
      else
        wb_mem_c.rdata <= (others => '0');
        wb_mem_c.ack   <= '0';
        wb_mem_c.err   <= '0';
      end if;
    end if;
  end process ext_mem_c_access;


  -- Wishbone IRQ Triggers ------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  irq_trigger: process(rst_gen, clk_gen)
  begin
    if (rst_gen = '0') then
      msi_ring <= '0';
      mei_ring <= '0';
    elsif rising_edge(clk_gen) then
      -- bus interface --
      wb_irq.rdata <= (others => '0');
      wb_irq.ack   <= wb_irq.cyc and wb_irq.stb and wb_irq.we and and_reduce_f(wb_irq.sel);
      wb_irq.err   <= '0';
      -- trigger RISC-V platform IRQs --
      if ((wb_irq.cyc and wb_irq.stb and wb_irq.we and and_reduce_f(wb_irq.sel)) = '1') then
        msi_ring <= wb_irq.wdata(03); -- machine software interrupt
        mei_ring <= wb_irq.wdata(11); -- machine software interrupt
      end if;
    end if;
  end process irq_trigger;


end neorv32_vunit_tb_rtl;
