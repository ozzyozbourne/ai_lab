unit MXM_W0
  Sync
  Nop n=11
  Iw dtype="int8" entries=[0:W0,1:W1,2:W2,3:W3,4:W4,5:W5,6:W6,7:W7] expect=["W1[0]@0","W1[1]@0","W1[2]@0","W1[3]@0","W1[4]@0","W1[5]@0","W1[6]@0","W1[7]@0"]
  Iw dtype="int8" entries=[8:W0,9:W1,10:W2,11:W3,12:W4,13:W5,14:W6,15:W7] expect=["W1[8]@1","W1[9]@1","W1[10]@1","W1[11]@1","W1[12]@1","W1[13]@1","W1[14]@1","W1[15]@1"]
  Abc dtype="int8" src=W0 out=E0 n_rows=16 tag="W1x@2" expect=["x@2"]
unit MEM_W7
  Sync
  Nop n=7
  Read addr=0 out=W0 tag="W1[0]@0#0"
  Read addr=1 out=W0 tag="W1[8]@1#0"
unit MEM_W6
  Sync
  Nop n=6
  Read addr=0 out=W1 tag="W1[1]@0#0"
  Read addr=1 out=W1 tag="W1[9]@1#0"
unit MEM_W5
  Sync
  Nop n=5
  Read addr=0 out=W2 tag="W1[2]@0#0"
  Read addr=1 out=W2 tag="W1[10]@1#0"
unit MEM_W4
  Sync
  Nop n=4
  Read addr=0 out=W3 tag="W1[3]@0#0"
  Read addr=1 out=W3 tag="W1[11]@1#0"
unit MEM_W3
  Sync
  Nop n=3
  Read addr=0 out=W4 tag="W1[4]@0#0"
  Read addr=1 out=W4 tag="W1[12]@1#0"
  Nop n=15
  Read addr=2 out=E7 tag="b1@2#3"
unit MEM_W2
  Sync
  Nop n=2
  Read addr=0 out=W5 tag="W1[5]@0#0"
  Read addr=1 out=W5 tag="W1[13]@1#0"
  Nop n=17
  Read addr=2 out=E6 tag="b1@2#2"
unit MEM_W1
  Sync
  Nop n=1
  Read addr=0 out=W6 tag="W1[6]@0#0"
  Read addr=1 out=W6 tag="W1[14]@1#0"
  Nop n=19
  Read addr=2 out=E5 tag="b1@2#1"
unit MEM_W0
  Sync
  Read addr=0 out=W7 tag="W1[7]@0#0"
  Read addr=1 out=W7 tag="W1[15]@1#0"
  Nop n=21
  Read addr=2 out=E4 tag="b1@2#0"
unit VXM_A0
  Notify
  Nop n=26
  Vxm op="add" dtype="int32" a=E0 b=E4 out=E0 n=16 tag="W1x_b1@2" expect=["W1x@2","b1@2"]
  Vxm op="relu" dtype="int32" a=E0 b=- out=E0 n=16 tag="relu1@2" expect=["W1x_b1@2"]
  Vxm op="requant" dtype="int32" a=E0 b=- out=E0 n=16 out_dtype="int8" imm=8 tag="h@2" expect=["relu1@2"]
  Nop n=26
  Vxm op="add" dtype="int32" a=W0 b=W4 out=E0 n=8 tag="y@4" expect=["W2h@4","b2@4"]
unit MEM_E0
  Sync
  Read addr=1 out=W0 tag="x@2#0"
  Read addr=0 out=E7 tag="W2[7]@3#0"
  Nop n=28
  Write addr=3 src=E0 expect=["h@2#0"]
  Read addr=3 out=E0 tag="h@4#0"
  Nop n=20
  Read addr=2 out=W4 tag="b2@4#0"
  Nop n=4
  Write addr=4 src=E0 expect=["y@4#0"]
unit MEM_E1
  Sync
  Nop n=2
  Read addr=0 out=E6 tag="W2[6]@3#0"
  Nop n=48
  Read addr=1 out=W5 tag="b2@4#1"
  Nop n=6
  Write addr=2 src=E1 expect=["y@4#1"]
unit MEM_E2
  Sync
  Nop n=3
  Read addr=0 out=E5 tag="W2[5]@3#0"
  Nop n=46
  Read addr=1 out=W6 tag="b2@4#2"
  Nop n=8
  Write addr=2 src=E2 expect=["y@4#2"]
unit MEM_E3
  Sync
  Nop n=4
  Read addr=0 out=E4 tag="W2[4]@3#0"
  Nop n=44
  Read addr=1 out=W7 tag="b2@4#3"
  Nop n=10
  Write addr=2 src=E3 expect=["y@4#3"]
unit MEM_E4
  Sync
  Nop n=5
  Read addr=0 out=E3 tag="W2[3]@3#0"
unit MEM_E5
  Sync
  Nop n=6
  Read addr=0 out=E2 tag="W2[2]@3#0"
unit MEM_E6
  Sync
  Nop n=7
  Read addr=0 out=E1 tag="W2[1]@3#0"
unit MEM_E7
  Sync
  Nop n=8
  Read addr=0 out=E0 tag="W2[0]@3#0"
unit MXM_E0
  Sync
  Nop n=12
  Iw dtype="int8" entries=[0:E0,1:E1,2:E2,3:E3,4:E4,5:E5,6:E6,7:E7] expect=["W2[0]@3","W2[1]@3","W2[2]@3","W2[3]@3","W2[4]@3","W2[5]@3","W2[6]@3","W2[7]@3"]
  Nop n=29
  Abc dtype="int8" src=E0 out=W0 n_rows=8 tag="W2h@4" expect=["h@4"]
