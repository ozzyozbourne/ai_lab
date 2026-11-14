unit MXM_W0
  Sync
  Nop n=5
  Iw dtype="fp16" entries=[0:W0] expect=["mean_row[0]@1"]
  Nop n=16
  Abc dtype="fp16" src=W0 out=E0 n_rows=1 tag="n1_ms@2" expect=["n1_sq16@2"]
  Iw dtype="fp16" entries=[0:W0,1:W2,2:W4,3:W6] expect=["Wq[0]@3","Wq[1]@3","Wq[2]@3","Wq[3]@3"]
  Iw dtype="fp16" entries=[4:W0,5:W2,6:W4,7:W6] expect=["Wq[4]@4","Wq[5]@4","Wq[6]@4","Wq[7]@4"]
  Nop n=58
  Abc dtype="fp16" src=W0 out=E0 n_rows=8 tag="q@5" expect=["xg16@5"]
  Iw dtype="fp16" entries=[0:W0,1:W2,2:W4,3:W6] expect=["Wv[0]@9","Wv[1]@9","Wv[2]@9","Wv[3]@9"]
  Iw dtype="fp16" entries=[4:W0,5:W2,6:W4,7:W6] expect=["Wv[4]@10","Wv[5]@10","Wv[6]@10","Wv[7]@10"]
  Nop n=1
  Abc dtype="fp16" src=W0 out=E0 n_rows=8 tag="v@11" expect=["xg16@11"]
  Iw dtype="fp16" entries=[0:W0,1:W2,2:W4,3:W6] expect=["Vt0@19","Vt1@19","Vt2@19","Vt3@19"]
  Iw dtype="fp16" entries=[4:W0,5:W2,6:W4,7:W6] expect=["Vt4@20","Vt5@20","Vt6@20","Vt7@20"]
  Nop n=131
  Abc dtype="fp16" src=W0 out=E0 n_rows=8 tag="a_cache@21" expect=["p16@21"]
  Iw dtype="fp16" entries=[0:W0] expect=["mean_row[0]@27"]
  Nop n=71
  Abc dtype="fp16" src=W0 out=E0 n_rows=1 tag="n2_ms@28" expect=["n2_sq16@28"]
  Iw dtype="fp16" entries=[0:W0,1:W2,2:W4,3:W6] expect=["W1[0]@29","W1[1]@29","W1[2]@29","W1[3]@29"]
  Iw dtype="fp16" entries=[4:W0,5:W2,6:W4,7:W6] expect=["W1[4]@30","W1[5]@30","W1[6]@30","W1[7]@30"]
  Iw dtype="fp16" entries=[8:W0,9:W2,10:W4,11:W6] expect=["W1[8]@31","W1[9]@31","W1[10]@31","W1[11]@31"]
  Iw dtype="fp16" entries=[12:W0,13:W2,14:W4,15:W6] expect=["W1[12]@32","W1[13]@32","W1[14]@32","W1[15]@32"]
  Nop n=51
  Abc dtype="fp16" src=W0 out=E0 n_rows=16 tag="ff1@33" expect=["hg16@33"]
  Iw dtype="fp16" entries=[0:W0,1:W2,2:W4,3:W6] expect=["Wu[0]@37","Wu[1]@37","Wu[2]@37","Wu[3]@37"]
  Iw dtype="fp16" entries=[4:W0,5:W2,6:W4,7:W6] expect=["Wu[4]@38","Wu[5]@38","Wu[6]@38","Wu[7]@38"]
  Iw dtype="fp16" entries=[8:W0,9:W2,10:W4,11:W6] expect=["Wu[8]@39","Wu[9]@39","Wu[10]@39","Wu[11]@39"]
  Iw dtype="fp16" entries=[12:W0,13:W2,14:W4,15:W6] expect=["Wu[12]@40","Wu[13]@40","Wu[14]@40","Wu[15]@40"]
  Nop n=57
  Abc dtype="fp16" src=W0 out=E0 n_rows=16 tag="logits@41" expect=["h2_16@41"]
unit SXM_W
  Sync
  Nop n=45
  Distribute width=4 src=W0 out=E0 map=[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0] n=8 tag="n1_msb@2" expect=["n1_mse@2"]
  Nop n=271
  Distribute width=4 src=W0 out=E0 map=[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0] n=8 tag="n2_msb@28" expect=["n2_mse@28"]
unit MEM_W7
  Sync
  Nop n=1
  Read addr=0 out=W0 tag="mean_row[0]@1#0"
  Nop n=17
  Read addr=1 out=W0 tag="Wq[0]@3#0"
  Read addr=2 out=W0 tag="Wq[4]@4#0"
  Nop n=59
  Read addr=3 out=W0 tag="Wv[0]@9#0"
  Read addr=4 out=W0 tag="Wv[4]@10#0"
  Nop n=2
  Read addr=13 out=W0 tag="Vt0@19#0"
  Read addr=14 out=W0 tag="Vt4@20#0"
  Nop n=132
  Read addr=0 out=W0 tag="mean_row[0]@27#0"
  Nop n=72
  Read addr=5 out=W0 tag="W1[0]@29#0"
  Read addr=6 out=W0 tag="W1[4]@30#0"
  Read addr=7 out=W0 tag="W1[8]@31#0"
  Read addr=8 out=W0 tag="W1[12]@32#0"
  Nop n=52
  Read addr=9 out=W0 tag="Wu[0]@37#0"
  Read addr=10 out=W0 tag="Wu[4]@38#0"
  Read addr=11 out=W0 tag="Wu[8]@39#0"
  Read addr=12 out=W0 tag="Wu[12]@40#0"
unit MEM_W6
  Sync
  Read addr=0 out=W1 tag="mean_row[0]@1#1"
  Nop n=17
  Read addr=1 out=W1 tag="Wq[0]@3#1"
  Read addr=2 out=W1 tag="Wq[4]@4#1"
  Nop n=59
  Read addr=3 out=W1 tag="Wv[0]@9#1"
  Read addr=4 out=W1 tag="Wv[4]@10#1"
  Nop n=2
  Read addr=13 out=W1 tag="Vt0@19#1"
  Read addr=14 out=W1 tag="Vt4@20#1"
  Nop n=132
  Read addr=0 out=W1 tag="mean_row[0]@27#1"
  Nop n=72
  Read addr=5 out=W1 tag="W1[0]@29#1"
  Read addr=6 out=W1 tag="W1[4]@30#1"
  Read addr=7 out=W1 tag="W1[8]@31#1"
  Read addr=8 out=W1 tag="W1[12]@32#1"
  Nop n=52
  Read addr=9 out=W1 tag="Wu[0]@37#1"
  Read addr=10 out=W1 tag="Wu[4]@38#1"
  Read addr=11 out=W1 tag="Wu[8]@39#1"
  Read addr=12 out=W1 tag="Wu[12]@40#1"
unit MEM_W5
  Sync
  Nop n=17
  Read addr=0 out=W2 tag="Wq[1]@3#0"
  Read addr=1 out=W2 tag="Wq[5]@4#0"
  Nop n=59
  Read addr=2 out=W2 tag="Wv[1]@9#0"
  Read addr=3 out=W2 tag="Wv[5]@10#0"
  Nop n=2
  Read addr=12 out=W2 tag="Vt1@19#0"
  Read addr=13 out=W2 tag="Vt5@20#0"
  Nop n=205
  Read addr=4 out=W2 tag="W1[1]@29#0"
  Read addr=5 out=W2 tag="W1[5]@30#0"
  Read addr=6 out=W2 tag="W1[9]@31#0"
  Read addr=7 out=W2 tag="W1[13]@32#0"
  Nop n=52
  Read addr=8 out=W2 tag="Wu[1]@37#0"
  Read addr=9 out=W2 tag="Wu[5]@38#0"
  Read addr=10 out=W2 tag="Wu[9]@39#0"
  Read addr=11 out=W2 tag="Wu[13]@40#0"
unit MEM_W4
  Sync
  Nop n=16
  Read addr=0 out=W3 tag="Wq[1]@3#1"
  Read addr=1 out=W3 tag="Wq[5]@4#1"
  Nop n=59
  Read addr=2 out=W3 tag="Wv[1]@9#1"
  Read addr=3 out=W3 tag="Wv[5]@10#1"
  Nop n=2
  Read addr=12 out=W3 tag="Vt1@19#1"
  Read addr=13 out=W3 tag="Vt5@20#1"
  Nop n=205
  Read addr=4 out=W3 tag="W1[1]@29#1"
  Read addr=5 out=W3 tag="W1[5]@30#1"
  Read addr=6 out=W3 tag="W1[9]@31#1"
  Read addr=7 out=W3 tag="W1[13]@32#1"
  Nop n=52
  Read addr=8 out=W3 tag="Wu[1]@37#1"
  Read addr=9 out=W3 tag="Wu[5]@38#1"
  Read addr=10 out=W3 tag="Wu[9]@39#1"
  Read addr=11 out=W3 tag="Wu[13]@40#1"
unit MEM_W3
  Sync
  Nop n=15
  Read addr=0 out=W4 tag="Wq[2]@3#0"
  Read addr=1 out=W4 tag="Wq[6]@4#0"
  Nop n=59
  Read addr=2 out=W4 tag="Wv[2]@9#0"
  Read addr=3 out=W4 tag="Wv[6]@10#0"
  Nop n=2
  Read addr=12 out=W4 tag="Vt2@19#0"
  Read addr=13 out=W4 tag="Vt6@20#0"
  Nop n=14
  Write addr=17 src=E3 expect=["v@11#3"]
  Nop n=24
  Read addr=14 out=E3 tag="scale@13#3"
  Nop n=92
  Read addr=17 out=E3 tag="v@22#3"
  Nop n=72
  Read addr=4 out=W4 tag="W1[2]@29#0"
  Read addr=5 out=W4 tag="W1[6]@30#0"
  Read addr=6 out=W4 tag="W1[10]@31#0"
  Read addr=7 out=W4 tag="W1[14]@32#0"
  Nop n=37
  Read addr=15 out=E7 tag="g2@28#3"
  Nop n=14
  Read addr=8 out=W4 tag="Wu[2]@37#0"
  Read addr=9 out=W4 tag="Wu[6]@38#0"
  Read addr=10 out=W4 tag="Wu[10]@39#0"
  Read addr=11 out=W4 tag="Wu[14]@40#0"
  Nop n=43
  Read addr=16 out=E3 tag="b2@36#3"
unit MEM_W2
  Sync
  Nop n=14
  Read addr=0 out=W5 tag="Wq[2]@3#1"
  Read addr=1 out=W5 tag="Wq[6]@4#1"
  Nop n=59
  Read addr=2 out=W5 tag="Wv[2]@9#1"
  Read addr=3 out=W5 tag="Wv[6]@10#1"
  Nop n=2
  Read addr=12 out=W5 tag="Vt2@19#1"
  Read addr=13 out=W5 tag="Vt6@20#1"
  Nop n=16
  Write addr=17 src=E2 expect=["v@11#2"]
  Nop n=24
  Read addr=14 out=E2 tag="scale@13#2"
  Nop n=92
  Read addr=17 out=E2 tag="v@22#2"
  Nop n=70
  Read addr=4 out=W5 tag="W1[2]@29#1"
  Read addr=5 out=W5 tag="W1[6]@30#1"
  Read addr=6 out=W5 tag="W1[10]@31#1"
  Read addr=7 out=W5 tag="W1[14]@32#1"
  Nop n=39
  Read addr=15 out=E6 tag="g2@28#2"
  Nop n=12
  Read addr=8 out=W5 tag="Wu[2]@37#1"
  Read addr=9 out=W5 tag="Wu[6]@38#1"
  Read addr=10 out=W5 tag="Wu[10]@39#1"
  Read addr=11 out=W5 tag="Wu[14]@40#1"
  Nop n=45
  Read addr=16 out=E2 tag="b2@36#2"
unit MEM_W1
  Sync
  Nop n=11
  Write addr=17 src=W1 expect=["n1_sq16@0#1"]
  Read addr=17 out=W1 tag="n1_sq16@2#1"
  Read addr=0 out=W6 tag="Wq[3]@3#0"
  Read addr=1 out=W6 tag="Wq[7]@4#0"
  Nop n=59
  Read addr=2 out=W6 tag="Wv[3]@9#0"
  Read addr=3 out=W6 tag="Wv[7]@10#0"
  Nop n=2
  Read addr=12 out=W6 tag="Vt3@19#0"
  Read addr=13 out=W6 tag="Vt7@20#0"
  Nop n=18
  Write addr=18 src=E1 expect=["v@11#1"]
  Write addr=19 src=W1 expect=["q16@5#1"]
  Read addr=19 out=E1 tag="q16@13#1"
  Nop n=22
  Read addr=14 out=E1 tag="scale@13#1"
  Nop n=23
  Write addr=20 src=W1 expect=["e16@14#1"]
  Read addr=20 out=E1 tag="e16@16#1"
  Nop n=61
  Write addr=21 src=W1 expect=["p16@18#1"]
  Read addr=21 out=W1 tag="p16@21#1"
  Nop n=4
  Read addr=18 out=E1 tag="v@22#1"
  Nop n=68
  Read addr=4 out=W6 tag="W1[3]@29#0"
  Read addr=5 out=W6 tag="W1[7]@30#0"
  Read addr=6 out=W6 tag="W1[11]@31#0"
  Read addr=7 out=W6 tag="W1[15]@32#0"
  Nop n=41
  Read addr=15 out=E5 tag="g2@28#1"
  Nop n=8
  Write addr=22 src=W1 expect=["hg16@28#1"]
  Read addr=22 out=W1 tag="hg16@33#1"
  Read addr=8 out=W6 tag="Wu[3]@37#0"
  Read addr=9 out=W6 tag="Wu[7]@38#0"
  Read addr=10 out=W6 tag="Wu[11]@39#0"
  Read addr=11 out=W6 tag="Wu[15]@40#0"
  Nop n=23
  Write addr=23 src=W1 expect=["ff1_16@33#1"]
  Read addr=23 out=E1 tag="ff1_16@36#1"
  Nop n=22
  Read addr=16 out=E1 tag="b2@36#1"
  Nop n=8
  Write addr=24 src=W1 expect=["h2_16@36#1"]
  Read addr=24 out=W1 tag="h2_16@41#1"
unit MEM_W0
  Sync
  Nop n=10
  Write addr=17 src=W0 expect=["n1_sq16@0#0"]
  Read addr=17 out=W0 tag="n1_sq16@2#0"
  Read addr=0 out=W7 tag="Wq[3]@3#1"
  Read addr=1 out=W7 tag="Wq[7]@4#1"
  Nop n=59
  Read addr=2 out=W7 tag="Wv[3]@9#1"
  Read addr=3 out=W7 tag="Wv[7]@10#1"
  Nop n=2
  Read addr=12 out=W7 tag="Vt3@19#1"
  Read addr=13 out=W7 tag="Vt7@20#1"
  Nop n=19
  Write addr=19 src=W0 expect=["q16@5#0"]
  Write addr=18 src=E0 expect=["v@11#0"]
  Nop n=1
  Read addr=19 out=E0 tag="q16@13#0"
  Nop n=22
  Read addr=14 out=E0 tag="scale@13#0"
  Nop n=21
  Write addr=20 src=W0 expect=["e16@14#0"]
  Nop n=2
  Read addr=20 out=E0 tag="e16@16#0"
  Nop n=59
  Write addr=21 src=W0 expect=["p16@18#0"]
  Read addr=21 out=W0 tag="p16@21#0"
  Nop n=6
  Read addr=18 out=E0 tag="v@22#0"
  Nop n=66
  Read addr=4 out=W7 tag="W1[3]@29#1"
  Read addr=5 out=W7 tag="W1[7]@30#1"
  Read addr=6 out=W7 tag="W1[11]@31#1"
  Read addr=7 out=W7 tag="W1[15]@32#1"
  Nop n=43
  Read addr=15 out=E4 tag="g2@28#0"
  Nop n=6
  Write addr=22 src=W0 expect=["hg16@28#0"]
  Read addr=22 out=W0 tag="hg16@33#0"
  Read addr=8 out=W7 tag="Wu[3]@37#1"
  Read addr=9 out=W7 tag="Wu[7]@38#1"
  Read addr=10 out=W7 tag="Wu[11]@39#1"
  Read addr=11 out=W7 tag="Wu[15]@40#1"
  Nop n=23
  Write addr=23 src=W0 expect=["ff1_16@33#0"]
  Nop n=2
  Read addr=23 out=E0 tag="ff1_16@36#0"
  Nop n=22
  Read addr=16 out=E0 tag="b2@36#0"
  Nop n=6
  Write addr=24 src=W0 expect=["h2_16@36#0"]
  Read addr=24 out=W0 tag="h2_16@41#0"
unit VXM_A0
  Notify
  Nop n=6
  Vxm op="mul" dtype="fp32" a=W0 b=W0 out=E0 n=8 tag="n1_sq@0" expect=["x@0","x@0"]
  Nop n=1
  Vxm op="cast" dtype="fp32" a=E0 b=- out=W0 n=8 out_dtype="fp16" tag="n1_sq16@0" expect=["n1_sq@0"]
  Nop n=26
  Vxm op="add" dtype="fp32" a=E0 b=W0 out=W0 n=1 tag="n1_mse@2" expect=["n1_ms@2","eps@2"]
  Nop n=20
  Vxm op="rsqrt" dtype="fp32" a=E0 b=- out=E0 n=8 tag="n1_r@2" expect=["n1_msb@2"]
  Nop n=3
  Vxm op="mul" dtype="fp32" a=W0 b=E0 out=E0 n=8 tag="n1_n@2" expect=["x@2","n1_r@2"]
  Nop n=1
  Vxm op="mul" dtype="fp32" a=E0 b=W0 out=E0 n=8 tag="n1_g@2" expect=["n1_n@2","g1@2"]
  Nop n=1
  Vxm op="cast" dtype="fp32" a=E0 b=- out=E0 n=8 out_dtype="fp16" tag="xg16@2" expect=["n1_g@2"]
  Nop n=26
  Vxm op="cast" dtype="fp32" a=W0 b=- out=E0 n=8 out_dtype="fp16" tag="k16@8" expect=["k@8"]
  Nop n=4
  Vxm op="cast" dtype="fp32" a=E0 b=- out=W0 n=8 out_dtype="fp16" tag="q16@5" expect=["q@5"]
  Nop n=30
  Vxm op="mul" dtype="fp32" a=W0 b=E0 out=E0 n=4 tag="scaled@13" expect=["scores@13","scale@13"]
  Nop n=1
  Vxm op="exp" dtype="fp32" a=E0 b=- out=E0 n=4 tag="e@13" expect=["scaled@13"]
  Nop n=14
  Vxm op="cast" dtype="fp32" a=W0 b=- out=W0 n=4 out_dtype="fp16" tag="e16@14" expect=["e@14"]
  Nop n=32
  Vxm op="rsqrt" dtype="fp32" a=W0 b=- out=E0 n=4 tag="esum_r@16" expect=["esum_b@16"]
  Nop n=14
  Vxm op="mul" dtype="fp32" a=W0 b=W0 out=E0 n=4 tag="esum_inv@17" expect=["esum_r@17","esum_r@17"]
  Nop n=1
  Vxm op="mul" dtype="fp32" a=W0 b=E0 out=E0 n=4 tag="p@17" expect=["e@17","esum_inv@17"]
  Nop n=12
  Vxm op="cast" dtype="fp32" a=W0 b=- out=W0 n=4 out_dtype="fp16" tag="p16@18" expect=["p@18"]
  Nop n=12
  Vxm op="mul" dtype="fp32" a=W0 b=E0 out=E0 n=8 tag="a_new@22" expect=["p_last@22","v@22"]
  Nop n=13
  Vxm op="add" dtype="fp32" a=E0 b=W0 out=E0 n=8 tag="attn@21" expect=["a_cache@21","a_new@21"]
  Vxm op="cast" dtype="fp32" a=E0 b=- out=E0 n=8 out_dtype="fp16" tag="attn16@21" expect=["attn@21"]
  Nop n=26
  Vxm op="add" dtype="fp32" a=W4 b=W0 out=E0 n=8 tag="h1@25" expect=["x@25","o@25"]
  Nop n=11
  Vxm op="mul" dtype="fp32" a=W0 b=W0 out=E0 n=8 tag="n2_sq@26" expect=["h1@26","h1@26"]
  Nop n=1
  Vxm op="cast" dtype="fp32" a=E0 b=- out=E0 n=8 out_dtype="fp16" tag="n2_sq16@26" expect=["n2_sq@26"]
  Nop n=30
  Vxm op="add" dtype="fp32" a=E0 b=W0 out=W0 n=1 tag="n2_mse@28" expect=["n2_ms@28","eps@28"]
  Nop n=20
  Vxm op="rsqrt" dtype="fp32" a=E0 b=- out=E0 n=8 tag="n2_r@28" expect=["n2_msb@28"]
  Nop n=3
  Vxm op="mul" dtype="fp32" a=W0 b=E0 out=E0 n=8 tag="n2_n@28" expect=["h1@28","n2_r@28"]
  Nop n=1
  Vxm op="mul" dtype="fp32" a=E0 b=E4 out=E0 n=8 tag="n2_g@28" expect=["n2_n@28","g2@28"]
  Nop n=1
  Vxm op="cast" dtype="fp32" a=E0 b=- out=W0 n=8 out_dtype="fp16" tag="hg16@28" expect=["n2_g@28"]
  Nop n=26
  Vxm op="add" dtype="fp32" a=E0 b=W0 out=E0 n=16 tag="ff1_b@33" expect=["ff1@33","b1@33"]
  Vxm op="relu" dtype="fp32" a=E0 b=- out=E0 n=16 tag="ff1_relu@33" expect=["ff1_b@33"]
  Vxm op="cast" dtype="fp32" a=E0 b=- out=W0 n=16 out_dtype="fp16" tag="ff1_16@33" expect=["ff1_relu@33"]
  Nop n=30
  Vxm op="add" dtype="fp32" a=W0 b=E0 out=E0 n=8 tag="ff2_b@36" expect=["ff2@36","b2@36"]
  Vxm op="add" dtype="fp32" a=W0 b=E0 out=E0 n=8 tag="h2@36" expect=["h1@36","ff2_b@36"]
  Vxm op="cast" dtype="fp32" a=E0 b=- out=W0 n=8 out_dtype="fp16" tag="h2_16@36" expect=["h2@36"]
unit MEM_E0
  Sync
  Read addr=0 out=E7 tag="Wk[3]@6#1"
  Nop n=1
  Read addr=1 out=E7 tag="Wk[7]@7#1"
  Read addr=7 out=W0 tag="x@0#0"
  Nop n=28
  Read addr=8 out=W0 tag="eps@2#0"
  Nop n=24
  Read addr=7 out=W0 tag="x@2#0"
  Nop n=1
  Read addr=9 out=W0 tag="g1@2#0"
  Nop n=6
  Write addr=11 src=E0 expect=["xg16@2#0"]
  Read addr=11 out=E0 tag="xg16@8#0"
  Nop n=2
  Read addr=11 out=W0 tag="xg16@5#0"
  Nop n=3
  Read addr=11 out=W0 tag="xg16@11#0"
  Nop n=18
  Write addr=6 src=E1 expect=["k16@8#1"]
  Read addr=6 out=E7 tag="k16@12#1"
  Nop n=39
  Write addr=12 src=E0 expect=["e@13#0"]
  Nop n=6
  Read addr=12 out=W0 tag="e@14#0"
  Nop n=10
  Read addr=2 out=E7 tag="Wo[3]@23#1"
  Read addr=3 out=E7 tag="Wo[7]@24#1"
  Nop n=28
  Write addr=13 src=E0 expect=["esum_r@16#0"]
  Nop n=6
  Read addr=13 out=W0 tag="esum_r@17#0"
  Nop n=1
  Read addr=12 out=W0 tag="e@17#0"
  Nop n=5
  Write addr=14 src=E0 expect=["p@17#0"]
  Nop n=1
  Read addr=14 out=E0 tag="p@22#0"
  Nop n=4
  Read addr=14 out=W0 tag="p@18#0"
  Nop n=18
  Write addr=15 src=E0 expect=["a_new@22#0"]
  Nop n=7
  Read addr=15 out=W0 tag="a_new@21#0"
  Nop n=5
  Write addr=16 src=E0 expect=["attn16@21#0"]
  Read addr=16 out=E0 tag="attn16@25#0"
  Read addr=4 out=E7 tag="W2[3]@34#1"
  Read addr=5 out=E7 tag="W2[7]@35#1"
  Nop n=18
  Read addr=7 out=W4 tag="x@25#0"
  Nop n=4
  Write addr=17 src=E0 expect=["h1@25#0"]
  Nop n=6
  Read addr=17 out=W0 tag="h1@26#0"
  Nop n=6
  Write addr=18 src=E0 expect=["n2_sq16@26#0"]
  Nop n=2
  Read addr=18 out=W0 tag="n2_sq16@28#0"
  Nop n=22
  Read addr=8 out=W0 tag="eps@28#0"
  Nop n=24
  Read addr=17 out=W0 tag="h1@28#0"
  Nop n=30
  Read addr=10 out=W0 tag="b1@33#0"
  Nop n=33
  Read addr=17 out=W0 tag="h1@36#0"
  Nop n=31
  Write addr=19 src=E0 expect=["logits@41#0"]
unit MEM_E1
  Sync
  Nop n=1
  Read addr=0 out=E6 tag="Wk[3]@6#0"
  Read addr=7 out=W1 tag="x@0#1"
  Read addr=1 out=E6 tag="Wk[7]@7#0"
  Nop n=27
  Read addr=8 out=W1 tag="eps@2#1"
  Nop n=24
  Read addr=7 out=W1 tag="x@2#1"
  Nop n=1
  Read addr=9 out=W1 tag="g1@2#1"
  Nop n=8
  Write addr=11 src=E1 expect=["xg16@2#1"]
  Read addr=11 out=E1 tag="xg16@8#1"
  Read addr=11 out=W1 tag="xg16@5#1"
  Nop n=3
  Read addr=11 out=W1 tag="xg16@11#1"
  Nop n=20
  Write addr=6 src=E0 expect=["k16@8#0"]
  Read addr=6 out=E6 tag="k16@12#0"
  Nop n=39
  Write addr=12 src=E1 expect=["e@13#1"]
  Nop n=4
  Read addr=12 out=W1 tag="e@14#1"
  Nop n=12
  Read addr=2 out=E6 tag="Wo[3]@23#0"
  Read addr=3 out=E6 tag="Wo[7]@24#0"
  Nop n=28
  Write addr=13 src=E1 expect=["esum_r@16#1"]
  Nop n=4
  Read addr=13 out=W1 tag="esum_r@17#1"
  Nop n=1
  Read addr=12 out=W1 tag="e@17#1"
  Nop n=7
  Write addr=14 src=E1 expect=["p@17#1"]
  Nop n=1
  Read addr=14 out=E1 tag="p@22#1"
  Nop n=2
  Read addr=14 out=W1 tag="p@18#1"
  Nop n=20
  Write addr=15 src=E1 expect=["a_new@22#1"]
  Nop n=5
  Read addr=15 out=W1 tag="a_new@21#1"
  Nop n=7
  Write addr=16 src=E1 expect=["attn16@21#1"]
  Read addr=16 out=E1 tag="attn16@25#1"
  Read addr=4 out=E6 tag="W2[3]@34#0"
  Read addr=5 out=E6 tag="W2[7]@35#0"
  Nop n=16
  Read addr=7 out=W5 tag="x@25#1"
  Nop n=6
  Write addr=17 src=E1 expect=["h1@25#1"]
  Nop n=4
  Read addr=17 out=W1 tag="h1@26#1"
  Nop n=8
  Write addr=18 src=E1 expect=["n2_sq16@26#1"]
  Read addr=18 out=W1 tag="n2_sq16@28#1"
  Nop n=22
  Read addr=8 out=W1 tag="eps@28#1"
  Nop n=24
  Read addr=17 out=W1 tag="h1@28#1"
  Nop n=30
  Read addr=10 out=W1 tag="b1@33#1"
  Nop n=33
  Read addr=17 out=W1 tag="h1@36#1"
  Nop n=33
  Write addr=19 src=E1 expect=["logits@41#1"]
unit MEM_E2
  Sync
  Nop n=1
  Read addr=7 out=W2 tag="x@0#2"
  Read addr=0 out=E5 tag="Wk[2]@6#1"
  Nop n=1
  Read addr=1 out=E5 tag="Wk[6]@7#1"
  Nop n=25
  Read addr=8 out=W2 tag="eps@2#2"
  Nop n=24
  Read addr=7 out=W2 tag="x@2#2"
  Nop n=1
  Read addr=9 out=W2 tag="g1@2#2"
  Nop n=38
  Read addr=6 out=E5 tag="K2@12#1"
  Nop n=39
  Write addr=11 src=E2 expect=["e@13#2"]
  Nop n=2
  Read addr=11 out=W2 tag="e@14#2"
  Nop n=14
  Read addr=2 out=E5 tag="Wo[2]@23#1"
  Read addr=3 out=E5 tag="Wo[6]@24#1"
  Nop n=28
  Write addr=12 src=E2 expect=["esum_r@16#2"]
  Nop n=2
  Read addr=12 out=W2 tag="esum_r@17#2"
  Nop n=1
  Read addr=11 out=W2 tag="e@17#2"
  Nop n=9
  Write addr=13 src=E2 expect=["p@17#2"]
  Nop n=1
  Read addr=13 out=E2 tag="p@22#2"
  Read addr=13 out=W2 tag="p@18#2"
  Nop n=22
  Write addr=14 src=E2 expect=["a_new@22#2"]
  Nop n=3
  Read addr=14 out=W2 tag="a_new@21#2"
  Nop n=11
  Read addr=4 out=E5 tag="W2[2]@34#1"
  Read addr=5 out=E5 tag="W2[6]@35#1"
  Nop n=14
  Read addr=7 out=W6 tag="x@25#2"
  Nop n=8
  Write addr=15 src=E2 expect=["h1@25#2"]
  Nop n=2
  Read addr=15 out=W2 tag="h1@26#2"
  Nop n=32
  Read addr=8 out=W2 tag="eps@28#2"
  Nop n=24
  Read addr=15 out=W2 tag="h1@28#2"
  Nop n=30
  Read addr=10 out=W2 tag="b1@33#2"
  Nop n=33
  Read addr=15 out=W2 tag="h1@36#2"
  Nop n=35
  Write addr=16 src=E2 expect=["logits@41#2"]
unit MEM_E3
  Sync
  Read addr=7 out=W3 tag="x@0#3"
  Nop n=2
  Read addr=0 out=E4 tag="Wk[2]@6#0"
  Nop n=1
  Read addr=1 out=E4 tag="Wk[6]@7#0"
  Nop n=23
  Read addr=8 out=W3 tag="eps@2#3"
  Nop n=24
  Read addr=7 out=W3 tag="x@2#3"
  Nop n=1
  Read addr=9 out=W3 tag="g1@2#3"
  Nop n=40
  Read addr=6 out=E4 tag="K2@12#0"
  Nop n=39
  Write addr=11 src=E3 expect=["e@13#3"]
  Read addr=11 out=W3 tag="e@14#3"
  Nop n=16
  Read addr=2 out=E4 tag="Wo[2]@23#0"
  Read addr=3 out=E4 tag="Wo[6]@24#0"
  Nop n=28
  Write addr=12 src=E3 expect=["esum_r@16#3"]
  Read addr=12 out=W3 tag="esum_r@17#3"
  Nop n=1
  Read addr=11 out=W3 tag="e@17#3"
  Nop n=11
  Write addr=13 src=E3 expect=["p@17#3"]
  Read addr=13 out=W3 tag="p@18#3"
  Read addr=13 out=E3 tag="p@22#3"
  Nop n=23
  Write addr=14 src=E3 expect=["a_new@22#3"]
  Nop n=1
  Read addr=14 out=W3 tag="a_new@21#3"
  Nop n=13
  Read addr=4 out=E4 tag="W2[2]@34#0"
  Read addr=5 out=E4 tag="W2[6]@35#0"
  Nop n=12
  Read addr=7 out=W7 tag="x@25#3"
  Nop n=10
  Write addr=15 src=E3 expect=["h1@25#3"]
  Read addr=15 out=W3 tag="h1@26#3"
  Nop n=32
  Read addr=8 out=W3 tag="eps@28#3"
  Nop n=24
  Read addr=15 out=W3 tag="h1@28#3"
  Nop n=30
  Read addr=10 out=W3 tag="b1@33#3"
  Nop n=33
  Read addr=15 out=W3 tag="h1@36#3"
  Nop n=37
  Write addr=16 src=E3 expect=["logits@41#3"]
unit MEM_E4
  Sync
  Nop n=4
  Read addr=0 out=E3 tag="Wk[1]@6#1"
  Nop n=1
  Read addr=1 out=E3 tag="Wk[5]@7#1"
  Nop n=91
  Read addr=6 out=E3 tag="K1@12#1"
  Nop n=57
  Read addr=2 out=E3 tag="Wo[1]@23#1"
  Read addr=3 out=E3 tag="Wo[5]@24#1"
  Nop n=85
  Read addr=4 out=E3 tag="W2[1]@34#1"
  Read addr=5 out=E3 tag="W2[5]@35#1"
unit MEM_E5
  Sync
  Nop n=5
  Read addr=0 out=E2 tag="Wk[1]@6#0"
  Nop n=1
  Read addr=1 out=E2 tag="Wk[5]@7#0"
  Nop n=91
  Read addr=6 out=E2 tag="K1@12#0"
  Nop n=57
  Read addr=2 out=E2 tag="Wo[1]@23#0"
  Read addr=3 out=E2 tag="Wo[5]@24#0"
  Nop n=85
  Read addr=4 out=E2 tag="W2[1]@34#0"
  Read addr=5 out=E2 tag="W2[5]@35#0"
unit MEM_E6
  Sync
  Nop n=6
  Read addr=1 out=E1 tag="Wk[0]@6#1"
  Nop n=1
  Read addr=2 out=E1 tag="Wk[4]@7#1"
  Nop n=91
  Read addr=7 out=E1 tag="K0@12#1"
  Nop n=9
  Read addr=0 out=E1 tag="ones_row[0]@15#1"
  Nop n=47
  Read addr=3 out=E1 tag="Wo[0]@23#1"
  Read addr=4 out=E1 tag="Wo[4]@24#1"
  Nop n=85
  Read addr=5 out=E1 tag="W2[0]@34#1"
  Read addr=6 out=E1 tag="W2[4]@35#1"
unit MEM_E7
  Sync
  Nop n=7
  Read addr=1 out=E0 tag="Wk[0]@6#0"
  Nop n=1
  Read addr=2 out=E0 tag="Wk[4]@7#0"
  Nop n=91
  Read addr=7 out=E0 tag="K0@12#0"
  Nop n=9
  Read addr=0 out=E0 tag="ones_row[0]@15#0"
  Nop n=47
  Read addr=3 out=E0 tag="Wo[0]@23#0"
  Read addr=4 out=E0 tag="Wo[4]@24#0"
  Nop n=85
  Read addr=5 out=E0 tag="W2[0]@34#0"
  Read addr=6 out=E0 tag="W2[4]@35#0"
unit SXM_E
  Sync
  Nop n=166
  Distribute width=4 src=W0 out=W0 map=[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0] n=4 tag="esum_b@16" expect=["esum@16"]
  Nop n=42
  Distribute width=4 src=E0 out=W0 map=[3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3] n=8 tag="p_last@22" expect=["p@22"]
unit MXM_E0
  Sync
  Nop n=11
  Iw dtype="fp16" entries=[0:E0,1:E2,2:E4,3:E6] expect=["Wk[0]@6","Wk[1]@6","Wk[2]@6","Wk[3]@6"]
  Nop n=1
  Iw dtype="fp16" entries=[4:E0,5:E2,6:E4,7:E6] expect=["Wk[4]@7","Wk[5]@7","Wk[6]@7","Wk[7]@7"]
  Nop n=64
  Abc dtype="fp16" src=E0 out=W0 n_rows=8 tag="k@8" expect=["xg16@8"]
  Nop n=26
  Iw dtype="fp16" entries=[0:E0,1:E2,2:E4,3:E6] expect=["K0@12","K1@12","K2@12","k16@12"]
  Nop n=8
  Abc dtype="fp16" src=E0 out=W0 n_rows=4 tag="scores@13" expect=["q16@13"]
  Iw dtype="fp16" entries=[0:E0] expect=["ones_row[0]@15"]
  Nop n=46
  Abc dtype="fp16" src=E0 out=W0 n_rows=1 tag="esum@16" expect=["e16@16"]
  Iw dtype="fp16" entries=[0:E0,1:E2,2:E4,3:E6] expect=["Wo[0]@23","Wo[1]@23","Wo[2]@23","Wo[3]@23"]
  Iw dtype="fp16" entries=[4:E0,5:E2,6:E4,7:E6] expect=["Wo[4]@24","Wo[5]@24","Wo[6]@24","Wo[7]@24"]
  Nop n=84
  Abc dtype="fp16" src=E0 out=W0 n_rows=8 tag="o@25" expect=["attn16@25"]
  Iw dtype="fp16" entries=[0:E0,1:E2,2:E4,3:E6] expect=["W2[0]@34","W2[1]@34","W2[2]@34","W2[3]@34"]
  Iw dtype="fp16" entries=[4:E0,5:E2,6:E4,7:E6] expect=["W2[4]@35","W2[5]@35","W2[6]@35","W2[7]@35"]
  Nop n=131
  Abc dtype="fp16" src=E0 out=W0 n_rows=8 tag="ff2@36" expect=["ff1_16@36"]
