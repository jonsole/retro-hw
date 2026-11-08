---
status: accepted
---

# Each requester keeps its own address and data ports

We considered one shared address bus, with each requester putting its address up when it gets its ack, and rejected it. The ack comes a clock after the decision, too late for the address, so sharing needs the grant a cycle earlier and adds 20 ns to every access; and inside an FPGA a shared bus is still a mux or OR tree, so it would save only about 40-60 LUTs. Revisit only if LUTs get tight on the Z80 board.
