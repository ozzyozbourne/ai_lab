; SWX pipeline I/O: two pcap-file source ports, two pcap-file sink ports (no NICs)
port in 0 source mempool MEMPOOL0 file ./in.pcap loop 1 packets 0
port in 1 source mempool MEMPOOL0 file ./in.pcap loop 1 packets 0
port out 0 sink file ./swx_out0.pcap
port out 1 sink file ./swx_out1.pcap
