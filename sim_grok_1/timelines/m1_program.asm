unit MXM_W0
  Sync
  Nop n=11
  Iw dtype="int8" entries=[0:W0,1:W1,2:W2,3:W3,4:W4,5:W5,6:W6,7:W7] expect=["W[0]@0","W[1]@0","W[2]@0","W[3]@0","W[4]@0","W[5]@0","W[6]@0","W[7]@0"]
  Nop n=1
  Abc dtype="int8" src=W0 out=E0 n_rows=8 tag="Wx@1" expect=["x@1"]
unit MEM_W7
  Sync
  Nop n=7
  Read addr=0 out=W0 tag="W[0]@0#0"
unit MEM_W6
  Sync
  Nop n=6
  Read addr=0 out=W1 tag="W[1]@0#0"
unit MEM_W5
  Sync
  Nop n=5
  Read addr=0 out=W2 tag="W[2]@0#0"
unit MEM_W4
  Sync
  Nop n=4
  Read addr=0 out=W3 tag="W[3]@0#0"
unit MEM_W3
  Sync
  Nop n=3
  Read addr=0 out=W4 tag="W[4]@0#0"
  Nop n=16
  Read addr=1 out=E7 tag="b@1#3"
unit MEM_W2
  Sync
  Nop n=2
  Read addr=0 out=W5 tag="W[5]@0#0"
  Nop n=18
  Read addr=1 out=E6 tag="b@1#2"
unit MEM_W1
  Sync
  Nop n=1
  Read addr=0 out=W6 tag="W[6]@0#0"
  Nop n=20
  Read addr=1 out=E5 tag="b@1#1"
unit MEM_W0
  Sync
  Read addr=0 out=W7 tag="W[7]@0#0"
  Nop n=22
  Read addr=1 out=E4 tag="b@1#0"
unit VXM_A0
  Notify
  Nop n=26
  Vxm op="add" dtype="int32" a=E0 b=E4 out=E0 n=8 tag="Wx_b@1" expect=["Wx@1","b@1"]
  Vxm op="relu" dtype="int32" a=E0 b=- out=E0 n=8 tag="y@1" expect=["Wx_b@1"]
unit MEM_E0
  Sync
  Read addr=0 out=W0 tag="x@1#0"
  Nop n=28
  Write addr=1 src=E0 expect=["y@1#0"]
unit MEM_E1
  Sync
  Nop n=30
  Write addr=0 src=E1 expect=["y@1#1"]
unit MEM_E2
  Sync
  Nop n=31
  Write addr=0 src=E2 expect=["y@1#2"]
unit MEM_E3
  Sync
  Nop n=32
  Write addr=0 src=E3 expect=["y@1#3"]
