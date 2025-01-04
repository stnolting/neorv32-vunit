# Testing the NEORV32 with VUnit

[![neorv32-vunit](https://img.shields.io/github/actions/workflow/status/stnolting/neorv32-vunit/vunit.yml?branch=main&longCache=true&style=flat-square&label=neorv32-vunit&logo=Github%20Actions&logoColor=fff)](https://github.com/stnolting/neorv32-vunit/actions/workflows/vunit.yml)

[VUnit](https://vunit.github.io) is a powerful open-source unit testing framework for VHDL/SystemVerilog.
It allows continuous and automated testing of HDL code by complementing traditional testing methodologies.
The motto of VUnit is _"testing early and often"_ through automation.

VUnit is composed by a http://vunit.github.io/py/ui.html[Python interface] and multiple optional
http://vunit.github.io/vhdl_libraries.html[VHDL libraries]. The Python interface allows declaring sources and
simulation options, and it handles the compilation, execution and gathering of the results regardless of the
simulator used. That allows having a single [`run.py`](sim/run.py) script to be used with any simulator.

On the other hand, VUnit's VHDL libraries provide utilities for assertions, logging, having virtual queues,
handling CSV files, etc. The [Verification Component Library](http://vunit.github.io/verification_components/user_guide.html)
uses those features for abstracting away bit-toggling when verifying standard interfaces such as Wishbone,
AXI, Avalon, UARTs, etc.

Testbench sources in `sim` (such as `sim/neorv32_vunit_tb.vhd` and `sim/uart_rx*.vhd`) use VUnit's VHDL
libraries for testing NEORV32 and peripherals. The entry-point for executing the tests is `sim/run.py`.

```bash
# ./sim/run.py -l
neorv32.neorv32_vunit_tb.all
Listed 1 tests

# ./sim/run.py -v
Compiling into neorv32:   rtl/core/neorv32_uart.vhd   passed
Compiling into neorv32:   rtl/core/neorv32_twi.vhd    passed
Compiling into neorv32:   rtl/core/neorv32_trng.vhd   passed
...
```
