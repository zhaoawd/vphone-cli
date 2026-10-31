0x1c4424c38 ldr      x21, [sp, #0x80]
0x1c4424c3c mov      x0, x21
0x1c4424c40 bl       #0x1ca1f1fd0
0x1c4424c44 cmp      x0, #1
0x1c4424c48 b.lt     #0x1c4424d08
0x1c4424c4c mov      x19, #0
0x1c4424c50 adrp     x8, #0x1ff49e000
0x1c4424c54 ldr      x20, [x8, #0xa08]
0x1c4424c58 adrp     x8, #0x1ff49e000
0x1c4424c5c add      x8, x8, #0x768
0x1c4424c60 ldr      x22, [x8]
0x1c4424c64 adrp     x8, #0x1ff49e000
0x1c4424c68 add      x8, x8, #0x760
0x1c4424c6c ldr      x23, [x8]
0x1c4424c70 mov      x0, x21
0x1c4424c74 mov      x1, x19
0x1c4424c78 bl       #0x1ca1f2000
0x1c4424c7c bl       #0x1ca1f2af0
0x1c4424c80 mov      x24, x0
0x1c4424c84 ldr      x0, [x0, #0x68]
0x1c4424c88 mov      x2, x20
0x1c4424c8c bl       #0x1c4d22800
0x1c4424c90 cbz      x0, #0x1c4424c9c
0x1c4424c94 ldr      x8, [sp, #0x50]
0x1c4424c98 str      x8, [x24, #0x80]
0x1c4424c9c ldr      x0, [x24, #0x68]
0x1c4424ca0 mov      x2, x22
0x1c4424ca4 bl       #0x1c4d22800
0x1c4424ca8 bl       #0x1c4d1b3e0
0x1c4424cac mov      x21, x0
0x1c4424cb0 ldr      x0, [x24, #0x68]
0x1c4424cb4 mov      x2, x23
0x1c4424cb8 bl       #0x1c4d22800
0x1c4424cbc bl       #0x1c4d1b3e0
0x1c4424cc0 sub      w8, w21, #7
0x1c4424cc4 cmp      w8, #3
0x1c4424cc8 b.hs     #0x1c4424cdc
0x1c4424ccc cmp      w0, #2
0x1c4424cd0 fcsel    s0, s9, s10, eq
0x1c4424cd4 ldr      x21, [sp, #0x80]
0x1c4424cd8 b        #0x1c4424cf0
0x1c4424cdc fmov     s0, s8
0x1c4424ce0 cmp      w21, #3
0x1c4424ce4 ldr      x21, [sp, #0x80]
0x1c4424ce8 b.eq     #0x1c4424cf0
0x1c4424cec fmov     s0, #1.00000000
0x1c4424cf0 str      s0, [x24, #0x88]
0x1c4424cf4 add      x19, x19, #1
0x1c4424cf8 mov      x0, x21
0x1c4424cfc bl       #0x1ca1f1fd0
0x1c4424d00 cmp      x0, x19
0x1c4424d04 b.gt     #0x1c4424c70
0x1c4424d08 ldr      x1, [sp, #0x40]
0x1c4424d0c cmn      x1, #1
0x1c4424d10 ldr      x22, [sp, #0x28]
0x1c4424d14 b.eq     #0x1c4424d20
0x1c4424d18 mov      x0, x21
0x1c4424d1c bl       #0x1ca1f2020
0x1c4424d20 adrp     x19, #0x205348000
0x1c4424d24 ldr      x0, [x19, #0x9e0]
0x1c4424d28 bl       #0x1ca1f4280
0x1c4424d2c adrp     x8, #0x205348000
0x1c4424d30 ldr      x0, [x8, #0x9e8]
0x1c4424d34 mov      x2, x21
0x1c4424d38 bl       #0x1c4d05c60
0x1c4424d3c ldr      x0, [x19, #0x9e0]
0x1c4424d40 bl       #0x1ca1f4290
0x1c4424d44 adrp     x8, #0x205349000
0x1c4424d48 ldr      x0, [x8, #0x1c0]
0x1c4424d4c bl       #0x1c4d09360
0x1c4424d50 ldr      w21, [sp, #0x24]
0x1c4424d54 mov      x25, x21
0x1c4424d58 tbz      w21, #1, #0x1c4424e3c
0x1c4424d5c movi     v0.2d, #0000000000000000
0x1c4424d60 stp      q0, q0, [sp, #0x170]
0x1c4424d64 stp      q0, q0, [sp, #0x150]
0x1c4424d68 mov      x0, x22
0x1c4424d6c bl       #0x1c4d42580
0x1c4424d70 mov      x19, x0
0x1c4424d74 add      x2, sp, #0x150
0x1c4424d78 add      x3, sp, #0xd0
0x1c4424d7c mov      w4, #0x10
0x1c4424d80 bl       #0x1c4d0d1e0
0x1c4424d84 cbz      x0, #0x1c4424e3c
0x1c4424d88 mov      x20, x0
0x1c4424d8c ldr      x8, [sp, #0x160]
0x1c4424d90 ldr      x22, [x8]
0x1c4424d94 mov      w23, #0x756e
0x1c4424d98 movk     w23, #0x736f, lsl #16
0x1c4424d9c mov      x24, #0
0x1c4424da0 ldr      x8, [sp, #0x160]
0x1c4424da4 ldr      x8, [x8]
0x1c4424da8 cmp      x8, x22
0x1c4424dac b.eq     #0x1c4424db8
0x1c4424db0 mov      x0, x19
0x1c4424db4 bl       #0x1ca1f60e0
0x1c4424db8 ldr      x8, [sp, #0x158]
0x1c4424dbc ldr      x21, [x8, x24, lsl #3]
0x1c4424dc0 mov      x0, x21
0x1c4424dc4 bl       #0x1c4d20000
0x1c4424dc8 cmp      w0, w23
0x1c4424dcc b.ne     #0x1c4424e14
0x1c4424dd0 str      xzr, [sp, #0x190]
0x1c4424dd4 ldp      x0, x8, [sp, #0xa8]
0x1c4424dd8 ldp      q0, q1, [x8]
0x1c4424ddc stp      q0, q1, [sp, #0x1b0]
0x1c4424de0 add      x2, sp, #0x1b0
0x1c4424de4 add      x3, sp, #0x190
0x1c4424de8 mov      x1, x21
0x1c4424dec bl       #0x1c475205c
0x1c4424df0 ldr      x21, [sp, #0x190]
0x1c4424df4 cmp      w0, #0
0x1c4424df8 ccmp     x21, #0, #4, eq
0x1c4424dfc b.eq     #0x1c4424e14
0x1c4424e00 ldr      x0, [sp, #0x80]
0x1c4424e04 mov      x1, x21
0x1c4424e08 bl       #0x1ca1f1f60
0x1c4424e0c mov      x0, x21
0x1c4424e10 bl       #0x1ca1f2420
0x1c4424e14 add      x24, x24, #1
0x1c4424e18 cmp      x20, x24
0x1c4424e1c b.ne     #0x1c4424da0
0x1c4424e20 add      x2, sp, #0x150
0x1c4424e24 add      x3, sp, #0xd0
0x1c4424e28 mov      x0, x19
0x1c4424e2c mov      w4, #0x10
0x1c4424e30 bl       #0x1c4d0d1e0
0x1c4424e34 mov      x20, x0
0x1c4424e38 cbnz     x0, #0x1c4424d9c
0x1c4424e3c tbz      w25, #3, #0x1c4424e78
0x1c4424e40 str      xzr, [sp, #0x190]
0x1c4424e44 ldp      x0, x8, [sp, #0xa8]
0x1c4424e48 ldp      q0, q1, [x8]
0x1c4424e4c stp      q0, q1, [sp, #0x1b0]
0x1c4424e50 add      x2, sp, #0x1b0
0x1c4424e54 add      x3, sp, #0x190
0x1c4424e58 bl       #0x1c4426364
0x1c4424e5c cbnz     w0, #0x1c4424e78
0x1c4424e60 ldr      x19, [sp, #0x190]
0x1c4424e64 ldr      x0, [sp, #0x80]
0x1c4424e68 mov      x1, x19
0x1c4424e6c bl       #0x1ca1f1f60
0x1c4424e70 mov      x0, x19
0x1c4424e74 bl       #0x1ca1f2420
0x1c4424e78 adrp     x8, #0x205348000
0x1c4424e7c ldr      w8, [x8, #0x30]
0x1c4424e80 cbz      w8, #0x1c4424f90
0x1c4424e84 str      wzr, [sp, #0x23c]
0x1c4424e88 strb     wzr, [sp, #0x23b]
0x1c4424e8c adrp     x23, #0x205348000
0x1c4424e90 ldr      x0, [x23, #0x28]
0x1c4424e94 add      x2, sp, #0x23c
0x1c4424e98 add      x3, sp, #0x23b
0x1c4424e9c mov      w1, #1
0x1c4424ea0 bl       #0x1ca1f59d0
0x1c4424ea4 mov      x19, x0
0x1c4424ea8 ldr      w21, [sp, #0x23c]
0x1c4424eac ldrb     w20, [sp, #0x23b]
0x1c4424eb0 mov      x1, x20
0x1c4424eb4 bl       #0x1ca1f64a0
0x1c4424eb8 and      w8, w21, #0xfffffffe
0x1c4424ebc cmp      w0, #0
0x1c4424ec0 csel     w22, w21, w8, ne
0x1c4424ec4 cbz      w22, #0x1c4424f68
0x1c4424ec8 ldr      x0, [sp, #0x80]
0x1c4424ecc bl       #0x1ca1f1fd0
0x1c4424ed0 mov      x21, x0
0x1c4424ed4 ldr      x8, [sp, #0xb0]
0x1c4424ed8 ldp      q0, q1, [x8]
0x1c4424edc stp      q0, q1, [sp, #0x1b0]
0x1c4424ee0 add      x0, sp, #0x1b0
0x1c4424ee4 bl       #0x1c4421504
0x1c4424ee8 adrp     x8, #0x1c4a0a000
0x1c4424eec ldr      d0, [x8, #0x290]
0x1c4424ef0 str      s0, [sp, #0x190]
0x1c4424ef4 adrp     x8, #0x1c4be6000
0x1c4424ef8 add      x8, x8, #0x113
0x1c4424efc add      x9, sp, #0x190
0x1c4424f00 stur     x8, [x9, #4]
0x1c4424f04 mov      w8, #0x400
0x1c4424f08 strh     w8, [sp, #0x19c]
0x1c4424f0c stur     w21, [x9, #0xe]
0x1c4424f10 strh     w8, [sp, #0x1a2]
0x1c4424f14 str      w25, [sp, #0x1a4]
0x1c4424f18 strh     w8, [sp, #0x1a8]
0x1c4424f1c stur     w0, [x9, #0x1a]
0x1c4424f20 mov      w8, #0x1e
0x1c4424f24 str      w8, [sp, #8]
0x1c4424f28 add      x8, sp, #0x190
0x1c4424f2c str      x8, [sp]
0x1c4424f30 adrp     x4, #0x1c4412000
0x1c4424f34 add      x4, x4, #0
0x1c4424f38 adrp     x7, #0x1c4c26000
0x1c4424f3c add      x7, x7, #0x717
0x1c4424f40 add      x2, sp, #0x1b0
0x1c4424f44 mov      x0, x22
0x1c4424f48 mov      x1, #0
0x1c4424f4c mov      w3, #0x80
0x1c4424f50 mov      x5, x19
0x1c4424f54 mov      x6, x20
0x1c4424f58 bl       #0x1ca1f50b0
0x1c4424f5c mov      x3, x0
0x1c4424f60 ldr      w21, [sp, #0x23c]
0x1c4424f64 b        #0x1c4424f6c
0x1c4424f68 mov      x3, #0
0x1c4424f6c ldr      x0, [x23, #0x28]
0x1c4424f70 add      x8, sp, #0x1b0
0x1c4424f74 cmp      x3, x8
0x1c4424f78 cset     w4, ne
0x1c4424f7c mov      w1, #1
0x1c4424f80 mov      w2, #1
0x1c4424f84 mov      x5, x21
0x1c4424f88 mov      x6, #0
0x1c4424f8c bl       #0x1ca1f59c0
0x1c4424f90 ldr      x0, [sp, #0x80]
0x1c4424f94 add      sp, sp, #0x3e0
0x1c4424f98 ldp      x29, x30, [sp, #0x80]
0x1c4424f9c ldp      x20, x19, [sp, #0x70]
0x1c4424fa0 ldp      x22, x21, [sp, #0x60]
0x1c4424fa4 ldp      x24, x23, [sp, #0x50]
0x1c4424fa8 ldp      x26, x25, [sp, #0x40]
0x1c4424fac ldp      x28, x27, [sp, #0x30]
0x1c4424fb0 ldp      d9, d8, [sp, #0x20]
0x1c4424fb4 ldp      d11, d10, [sp, #0x10]
0x1c4424fb8 ldp      d13, d12, [sp], #0x90
0x1c4424fbc retab    
0x1c4424fc0 bl       #0x1c49adb5c
0x1c4424fc4 b        #0x1c442444c
0x1c4424fc8 pacibsp  
0x1c4424fcc sub      sp, sp, #0x70
0x1c4424fd0 stp      x22, x21, [sp, #0x40]
0x1c4424fd4 stp      x20, x19, [sp, #0x50]
0x1c4424fd8 stp      x29, x30, [sp, #0x60]
0x1c4424fdc add      x29, sp, #0x60
0x1c4424fe0 mov      x20, x1
0x1c4424fe4 mov      x19, x0
0x1c4424fe8 bl       #0x1c4d42580
0x1c4424fec mov      x21, x0
0x1c4424ff0 bl       #0x1c4d0d1c0
0x1c4424ff4 cbz      x0, #0x1c4425078
0x1c4424ff8 adrp     x8, #0x205348000
0x1c4424ffc ldr      x8, [x8, #0xa90]
0x1c4425000 cmn      x8, #1
0x1c4425004 b.ne     #0x1c4425080
0x1c4425008 add      x8, sp, #8
0x1c442500c adrp     x16, #0x1fe4ed000
0x1c4425010 ldr      x16, [x16, #0x820]
0x1c4425014 mov      x17, x8
0x1c4425018 movk     x17, #0x6ae1, lsl #48
0x1c442501c pacda    x16, x17
0x1c4425020 str      x16, [sp, #8]
0x1c4425024 adrp     x9, #0x1c4a0a000
0x1c4425028 ldr      d0, [x9, #0x1e0]
0x1c442502c str      d0, [sp, #0x10]
0x1c4425030 add      x8, x8, #0x10
0x1c4425034 adrp     x16, #0x1c4751000
0x1c4425038 add      x16, x16, #0x1a0
0x1c442503c pacia    x16, x8
0x1c4425040 adrp     x8, #0x1ff49b000
0x1c4425044 add      x8, x8, #0x3a0
0x1c4425048 stp      x16, x8, [sp, #0x18]
0x1c442504c strb     w20, [sp, #0x38]
0x1c4425050 stp      x21, x19, [sp, #0x28]
0x1c4425054 adrp     x8, #0x205348000
0x1c4425058 ldr      x8, [x8, #0xae8]
0x1c442505c cmn      x8, #1
0x1c4425060 b.ne     #0x1c4425088
0x1c4425064 ldp      x29, x30, [sp, #0x60]
0x1c4425068 ldp      x20, x19, [sp, #0x50]
0x1c442506c ldp      x22, x21, [sp, #0x40]
0x1c4425070 add      sp, sp, #0x70
0x1c4425074 retab    
0x1c4425078 bl       #0x1c49adb70
0x1c442507c b        #0x1c4425064
0x1c4425080 bl       #0x1c49adb5c
0x1c4425084 b        #0x1c4425008
0x1c4425088 adrp     x0, #0x205348000
0x1c442508c add      x0, x0, #0xae8
0x1c4425090 add      x1, sp, #8
0x1c4425094 bl       #0x1c49d4868
0x1c4425098 b        #0x1c4425064
0x1c442509c adrp     x8, #0x205349000
0x1c44250a0 ldr      x8, [x8, #0x2f8]
0x1c44250a4 cmn      x8, #1
0x1c44250a8 b.ne     #0x1c44250b8
0x1c44250ac adrp     x8, #0x205349000
0x1c44250b0 ldr      x0, [x8, #0x2e0]
0x1c44250b4 ret      
0x1c44250b8 pacibsp  
0x1c44250bc stp      x29, x30, [sp, #-0x10]!
0x1c44250c0 mov      x29, sp
0x1c44250c4 bl       #0x1c4426518
0x1c44250c8 ldp      x29, x30, [sp], #0x10
0x1c44250cc autibsp  
0x1c44250d0 b        #0x1c44250ac
0x1c44250d4 pacibsp  
0x1c44250d8 sub      sp, sp, #0x80
0x1c44250dc stp      x24, x23, [sp, #0x40]
0x1c44250e0 stp      x22, x21, [sp, #0x50]
0x1c44250e4 stp      x20, x19, [sp, #0x60]
0x1c44250e8 stp      x29, x30, [sp, #0x70]
0x1c44250ec add      x29, sp, #0x70
0x1c44250f0 str      xzr, [sp, #8]
0x1c44250f4 cbz      x1, #0x1c442525c
0x1c44250f8 mov      x19, x1
0x1c44250fc mov      x21, x0
0x1c4425100 adrp     x8, #0x1fe462000
0x1c4425104 ldr      x8, [x8, #0x480]
0x1c4425108 ldr      x20, [x8]
0x1c442510c bl       #0x1c442509c
0x1c4425110 mov      x2, x0
0x1c4425114 adrp     x1, #0x209c6a000
0x1c4425118 add      x1, x1, #0x858
0x1c442511c add      x3, sp, #8
0x1c4425120 mov      x0, x20
0x1c4425124 bl       #0x1ca1f2bc0
0x1c4425128 cbnz     w0, #0x1c4425268
0x1c442512c ldr      x0, [sp, #8]
0x1c4425130 bl       #0x1ca1f2af0
0x1c4425134 mov      x20, x0
0x1c4425138 adrp     x8, #0x20308c000
0x1c442513c ldr      x1, [x8, #0xb48]
0x1c4425140 mov      x0, x21
0x1c4425144 bl       #0x1ca1f6d40
0x1c4425148 mov      x2, x0
0x1c442514c str      x0, [x20]
0x1c4425150 adrp     x8, #0x205349000
0x1c4425154 ldr      x0, [x8, #0x2c8]
0x1c4425158 ldr      x1, [sp, #8]
0x1c442515c bl       #0x1ca1f44b0
0x1c4425160 cbnz     w0, #0x1c4425274
0x1c4425164 adrp     x8, #0x20308c000
0x1c4425168 ldr      x1, [x8, #0xb50]
0x1c442516c mov      x0, x21
0x1c4425170 bl       #0x1ca1f6d40
0x1c4425174 str      w0, [x20, #0x34]
0x1c4425178 sub      w8, w0, #7
0x1c442517c cmn      w8, #3
0x1c4425180 b.hi     #0x1c4425230
0x1c4425184 adrp     x8, #0x20308c000
0x1c4425188 ldr      x1, [x8, #0xb58]
0x1c442518c add      x2, x20, #0x20
0x1c4425190 mov      x0, x21
0x1c4425194 bl       #0x1ca1f4390
0x1c4425198 cbnz     w0, #0x1c4425280
0x1c442519c adrp     x8, #0x1fe461000
0x1c44251a0 ldr      x0, [x8, #0xf70]
0x1c44251a4 bl       #0x1ca1f6050
0x1c44251a8 mov      x22, x0
0x1c44251ac adrp     x8, #0x20308c000
0x1c44251b0 ldr      x1, [x8, #0xb60]
0x1c44251b4 mov      x0, x21
0x1c44251b8 bl       #0x1ca1f6d50
0x1c44251bc mov      x23, x0
0x1c44251c0 adrp     x8, #0x20308c000
0x1c44251c4 ldr      x1, [x8, #0xb68]
0x1c44251c8 mov      x0, x21
0x1c44251cc bl       #0x1ca1f6cd0
0x1c44251d0 add      x8, sp, #0x10
0x1c44251d4 adrp     x16, #0x1fe4ed000
0x1c44251d8 ldr      x16, [x16, #0x820]
0x1c44251dc mov      x17, x8
0x1c44251e0 movk     x17, #0x6ae1, lsl #48
0x1c44251e4 pacda    x16, x17
0x1c44251e8 str      x16, [sp, #0x10]
0x1c44251ec adrp     x9, #0x1c4a0a000
0x1c44251f0 ldr      d0, [x9, #0x1e0]
0x1c44251f4 str      d0, [sp, #0x18]
0x1c44251f8 add      x8, x8, #0x10
0x1c44251fc adrp     x16, #0x1c442f000
0x1c4425200 add      x16, x16, #0x49c
0x1c4425204 pacia    x16, x8
0x1c4425208 adrp     x8, #0x1ff494000
0x1c442520c add      x8, x8, #0xc10
0x1c4425210 stp      x16, x8, [sp, #0x20]
0x1c4425214 eor      w8, w0, #1
0x1c4425218 str      x22, [sp, #0x30]
0x1c442521c strb     w8, [sp, #0x38]
0x1c4425220 add      x1, sp, #0x10
0x1c4425224 mov      x0, x23
0x1c4425228 bl       #0x1ca1f6ad0
0x1c442522c str      x22, [x20, #0x28]
0x1c4425230 mov      w22, #0
0x1c4425234 str      wzr, [x20, #0x30]
0x1c4425238 ldr      x8, [sp, #8]
0x1c442523c str      x8, [x19]
0x1c4425240 mov      x0, x22
0x1c4425244 ldp      x29, x30, [sp, #0x70]
0x1c4425248 ldp      x20, x19, [sp, #0x60]
0x1c442524c ldp      x22, x21, [sp, #0x50]
0x1c4425250 ldp      x24, x23, [sp, #0x40]
0x1c4425254 add      sp, sp, #0x80
0x1c4425258 retab    
0x1c442525c bl       #0x1c47d41e8
0x1c4425260 mov      w22, #-0x31ec
0x1c4425264 b        #0x1c4425240
0x1c4425268 mov      x22, x0
0x1c442526c bl       #0x1c47d4080
0x1c4425270 b        #0x1c4425240
0x1c4425274 mov      x22, x0
0x1c4425278 bl       #0x1c47d40f8
0x1c442527c b        #0x1c4425240
0x1c4425280 mov      x22, x0
0x1c4425284 bl       #0x1c47d4170
0x1c4425288 b        #0x1c4425240
0x1c442528c pacibsp  
0x1c4425290 stp      x20, x19, [sp, #-0x20]!
0x1c4425294 stp      x29, x30, [sp, #0x10]
0x1c4425298 add      x29, sp, #0x10
0x1c442529c mov      x19, x8
0x1c44252a0 adrp     x8, #0x205349000
0x1c44252a4 ldr      x8, [x8, #0x258]
0x1c44252a8 cmn      x8, #1
0x1c44252ac b.ne     #0x1c44252cc
0x1c44252b0 adrp     x8, #0x205349000
0x1c44252b4 add      x8, x8, #0x260
0x1c44252b8 ldp      q0, q1, [x8]
0x1c44252bc stp      q0, q1, [x19]
0x1c44252c0 ldp      x29, x30, [sp, #0x10]
0x1c44252c4 ldp      x20, x19, [sp], #0x20
0x1c44252c8 retab    
0x1c44252cc bl       #0x1c44bf5e4
0x1c44252d0 b        #0x1c44252b0
0x1c44252d4 pacibsp  
0x1c44252d8 sub      sp, sp, #0x60
0x1c44252dc stp      x24, x23, [sp, #0x20]
0x1c44252e0 stp      x22, x21, [sp, #0x30]
0x1c44252e4 stp      x20, x19, [sp, #0x40]
0x1c44252e8 stp      x29, x30, [sp, #0x50]
0x1c44252ec add      x29, sp, #0x50
0x1c44252f0 mov      x19, x0
0x1c44252f4 stp      xzr, xzr, [sp, #0x10]
0x1c44252f8 bl       #0x1c4424334
0x1c44252fc adrp     x23, #0x205349000
0x1c4425300 cbnz     w0, #0x1c442543c
0x1c4425304 add      x2, sp, #0x18
0x1c4425308 mov      w0, #0x7263
0x1c442530c movk     w0, #0x6373, lsl #16
0x1c4425310 mov      x1, #0
0x1c4425314 bl       #0x1ca1f4340
0x1c4425318 cbnz     w0, #0x1c4425448
0x1c442531c ldr      x0, [sp, #0x18]
0x1c4425320 adrp     x8, #0x1fe465000
0x1c4425324 ldr      x8, [x8, #0x5b0]
0x1c4425328 ldr      x1, [x8]
0x1c442532c mov      w2, w19
0x1c4425330 bl       #0x1ca1f6da0
0x1c4425334 ldr      x0, [x23, #0x2c8]
0x1c4425338 ldr      x1, [sp, #0x18]
0x1c442533c add      x2, sp, #0x10
0x1c4425340 bl       #0x1ca1f4510
0x1c4425344 cbnz     w0, #0x1c4425454
0x1c4425348 ldr      x0, [sp, #0x10]
0x1c442534c adrp     x8, #0x1fe465000
0x1c4425350 ldr      x8, [x8, #0x5c8]
0x1c4425354 ldr      x1, [x8]
0x1c4425358 bl       #0x1ca1f6d50
0x1c442535c mov      x21, x0
0x1c4425360 adrp     x8, #0x1fe462000
0x1c4425364 ldr      x8, [x8, #0x480]
0x1c4425368 ldr      x19, [x8]
0x1c442536c bl       #0x1ca1f6b00
0x1c4425370 mov      x1, x0
0x1c4425374 adrp     x2, #0x1fe462000
0x1c4425378 ldr      x2, [x2, #0x9c0]
0x1c442537c mov      x0, x19
0x1c4425380 bl       #0x1ca1f1fb0
0x1c4425384 mov      x19, x0
0x1c4425388 cbz      x0, #0x1c4425464
0x1c442538c mov      x0, x21
0x1c4425390 bl       #0x1ca1f6b00
0x1c4425394 cbz      x0, #0x1c44253e4
0x1c4425398 mov      x22, #0
0x1c442539c mov      x0, x21
0x1c44253a0 mov      x1, x22
0x1c44253a4 bl       #0x1ca1f6b20
0x1c44253a8 str      xzr, [sp, #8]
0x1c44253ac add      x1, sp, #8
0x1c44253b0 bl       #0x1c44250d4
0x1c44253b4 cbnz     w0, #0x1c442542c
0x1c44253b8 ldr      x1, [sp, #8]
0x1c44253bc mov      x0, x19
0x1c44253c0 bl       #0x1ca1f1f60
0x1c44253c4 ldr      x0, [sp, #8]
0x1c44253c8 cbz      x0, #0x1c44253d0
0x1c44253cc bl       #0x1ca1f2420
0x1c44253d0 add      x22, x22, #1
0x1c44253d4 mov      x0, x21
0x1c44253d8 bl       #0x1ca1f6b00
0x1c44253dc cmp      x0, x22
0x1c44253e0 b.hi     #0x1c442539c
0x1c44253e4 mov      w20, #0
0x1c44253e8 ldr      x0, [sp, #0x10]
0x1c44253ec bl       #0x1ca1f44a0
0x1c44253f0 ldr      x0, [sp, #0x18]
0x1c44253f4 bl       #0x1ca1f44a0
0x1c44253f8 ldr      x0, [x23, #0x2c8]
0x1c44253fc adrp     x2, #0x1c4b71000
0x1c4425400 add      x2, x2, #0xb53
0x1c4425404 mov      x1, x20
0x1c4425408 mov      x3, #0
0x1c442540c bl       #0x1ca1f44e0
0x1c4425410 mov      x0, x19
0x1c4425414 ldp      x29, x30, [sp, #0x50]
0x1c4425418 ldp      x20, x19, [sp, #0x40]
0x1c442541c ldp      x22, x21, [sp, #0x30]
0x1c4425420 ldp      x24, x23, [sp, #0x20]
0x1c4425424 add      sp, sp, #0x60
0x1c4425428 retab    
0x1c442542c mov      x20, x0
0x1c4425430 add      x1, sp, #8
0x1c4425434 bl       #0x1c47d3f90
0x1c4425438 b        #0x1c44253e8
0x1c442543c mov      x20, x0
0x1c4425440 bl       #0x1c47d3e28
0x1c4425444 b        #0x1c442545c
0x1c4425448 mov      x20, x0
0x1c442544c bl       #0x1c47d3ea0
0x1c4425450 b        #0x1c442545c
0x1c4425454 mov      x20, x0
0x1c4425458 bl       #0x1c47d3f18
0x1c442545c mov      x19, #0
0x1c4425460 b        #0x1c44253e8
0x1c4425464 bl       #0x1c47d4008
0x1c4425468 mov      w20, #-0x31f2
0x1c442546c b        #0x1c44253e8
0x1c4425470 pacibsp  
0x1c4425474 sub      sp, sp, #0x50
0x1c4425478 stp      x24, x23, [sp, #0x10]
0x1c442547c stp      x22, x21, [sp, #0x20]
0x1c4425480 stp      x20, x19, [sp, #0x30]
0x1c4425484 stp      x29, x30, [sp, #0x40]
0x1c4425488 add      x29, sp, #0x40
0x1c442548c mov      x23, x2
0x1c4425490 mov      x21, x1
0x1c4425494 mov      x22, x0
0x1c4425498 str      wzr, [sp, #0xc]
0x1c442549c add      x1, sp, #0xc
0x1c44254a0 mov      x0, x21
0x1c44254a4 bl       #0x1ca1f4400
0x1c44254a8 cbnz     w0, #0x1c44258e0
0x1c44254ac bl       #0x1ca1f6080
0x1c44254b0 mov      x19, x0
0x1c44254b4 mov      w20, #-0x29a
0x1c44254b8 ldr      w8, [sp, #0xc]
0x1c44254bc mov      w9, #0x6472
0x1c44254c0 movk     w9, #0x6d6a, lsl #16
0x1c44254c4 cmp      w8, w9
0x1c44254c8 b.gt     #0x1c442552c
0x1c44254cc mov      w9, #0x7262
0x1c44254d0 movk     w9, #0x6373, lsl #16
0x1c44254d4 cmp      w8, w9
0x1c44254d8 b.gt     #0x1c44255dc
0x1c44254dc mov      w9, #0x646e
0x1c44254e0 movk     w9, #0x6368, lsl #16
0x1c44254e4 cmp      w8, w9
0x1c44254e8 b.gt     #0x1c442562c
0x1c44254ec mov      w9, #0x7063
0x1c44254f0 movk     w9, #0x632a, lsl #16
0x1c44254f4 cmp      w8, w9
0x1c44254f8 b.gt     #0x1c4425724
0x1c44254fc mov      w9, #0x7079
0x1c4425500 movk     w9, #0x2e63, lsl #16
0x1c4425504 cmp      w8, w9
0x1c4425508 b.eq     #0x1c4425808
0x1c442550c mov      w9, #0x6574
0x1c4425510 movk     w9, #0x2e73, lsl #16
0x1c4425514 cmp      w8, w9
0x1c4425518 b.ne     #0x1c4425840
0x1c442551c mov      x0, x22
0x1c4425520 mov      x1, x21
0x1c4425524 bl       #0x1c442fb18
0x1c4425528 b        #0x1c442583c
0x1c442552c mov      w9, #0x7061
0x1c4425530 movk     w9, #0x7374, lsl #16
0x1c4425534 cmp      w8, w9
0x1c4425538 b.gt     #0x1c4425588
0x1c442553c mov      w9, #0x7063
0x1c4425540 movk     w9, #0x726e, lsl #16
0x1c4425544 cmp      w8, w9
0x1c4425548 b.le     #0x1c44256e8
0x1c442554c mov      w9, #0x7364
0x1c4425550 movk     w9, #0x7366, lsl #16
0x1c4425554 cmp      w8, w9
0x1c4425558 b.le     #0x1c4425740
0x1c442555c mov      w9, #0x7365
0x1c4425560 movk     w9, #0x7366, lsl #16
0x1c4425564 cmp      w8, w9
0x1c4425568 b.eq     #0x1c44257e4
0x1c442556c mov      w9, #0x7569
0x1c4425570 movk     w9, #0x7373, lsl #16
0x1c4425574 cmp      w8, w9
0x1c4425578 b.ne     #0x1c4425840
0x1c442557c mov      x0, x21
0x1c4425580 bl       #0x1c4735394
0x1c4425584 b        #0x1c442583c
0x1c4425588 mov      w9, #0x6f67
0x1c442558c movk     w9, #0x7563, lsl #16
0x1c4425590 cmp      w8, w9
0x1c4425594 b.gt     #0x1c4425670
0x1c4425598 mov      w9, #0x7062
0x1c442559c movk     w9, #0x7374, lsl #16
0x1c44255a0 cmp      w8, w9
0x1c44255a4 b.eq     #0x1c44257c0
0x1c44255a8 mov      w9, #0x7064
0x1c44255ac movk     w9, #0x7374, lsl #16
0x1c44255b0 cmp      w8, w9
0x1c44255b4 b.eq     #0x1c4425788
0x1c44255b8 mov      w9, #0x6873
0x1c44255bc movk     w9, #0x7563, lsl #16
0x1c44255c0 cmp      w8, w9
0x1c44255c4 b.ne     #0x1c4425840
0x1c44255c8 mov      x0, x22
0x1c44255cc mov      x1, x21
0x1c44255d0 mov      x2, x23
0x1c44255d4 bl       #0x1c449a37c
0x1c44255d8 b        #0x1c442583c
0x1c44255dc mov      w9, #0x6472
0x1c44255e0 movk     w9, #0x6573, lsl #16
0x1c44255e4 cmp      w8, w9
0x1c44255e8 b.gt     #0x1c44256b0
0x1c44255ec mov      w9, #0x7263
0x1c44255f0 movk     w9, #0x6373, lsl #16
0x1c44255f4 cmp      w8, w9
0x1c44255f8 b.eq     #0x1c442581c
0x1c44255fc mov      w9, #0x6363
0x1c4425600 movk     w9, #0x6374, lsl #16
0x1c4425604 cmp      w8, w9
0x1c4425608 b.eq     #0x1c44257a0
0x1c442560c mov      w9, #0x7370
0x1c4425610 movk     w9, #0x6469, lsl #16
0x1c4425614 cmp      w8, w9
0x1c4425618 b.ne     #0x1c4425840
0x1c442561c mov      x0, x22
0x1c4425620 mov      x1, x21
0x1c4425624 bl       #0x1c4734aa0
0x1c4425628 b        #0x1c442583c
0x1c442562c mov      w9, #0x646f
0x1c4425630 movk     w9, #0x6368, lsl #16
0x1c4425634 cmp      w8, w9
0x1c4425638 b.eq     #0x1c4425774
0x1c442563c mov      w9, #0x7064
0x1c4425640 movk     w9, #0x6370, lsl #16
0x1c4425644 cmp      w8, w9
0x1c4425648 b.eq     #0x1c4425760
0x1c442564c mov      w9, #0x7372
0x1c4425650 movk     w9, #0x6370, lsl #16
0x1c4425654 cmp      w8, w9
0x1c4425658 b.ne     #0x1c4425840
0x1c442565c mov      x0, x22
0x1c4425660 mov      x1, x21
0x1c4425664 mov      x2, x23
0x1c4425668 bl       #0x1c4734c88
0x1c442566c b        #0x1c442583c
0x1c4425670 mov      w9, #0x6f68
0x1c4425674 movk     w9, #0x7563, lsl #16
0x1c4425678 cmp      w8, w9
0x1c442567c b.eq     #0x1c44257d0
0x1c4425680 mov      w9, #0x6c6b
0x1c4425684 movk     w9, #0x756e, lsl #16
0x1c4425688 cmp      w8, w9
0x1c442568c b.eq     #0x1c4425798
0x1c4425690 mov      w9, #0x7064
0x1c4425694 movk     w9, #0x756e, lsl #16
0x1c4425698 cmp      w8, w9
0x1c442569c b.ne     #0x1c4425840
0x1c44256a0 mov      x0, x22
0x1c44256a4 mov      x1, x21
0x1c44256a8 bl       #0x1c4735478
0x1c44256ac b        #0x1c442583c
0x1c44256b0 mov      w9, #0x6473
0x1c44256b4 movk     w9, #0x6573, lsl #16
0x1c44256b8 cmp      w8, w9
0x1c44256bc b.eq     #0x1c4425830
0x1c44256c0 mov      w9, #0x7661
0x1c44256c4 movk     w9, #0x696e, lsl #16
0x1c44256c8 cmp      w8, w9
0x1c44256cc b.eq     #0x1c44257b0
0x1c44256d0 mov      w9, #0x636b
0x1c44256d4 movk     w9, #0x6c6f, lsl #16
0x1c44256d8 cmp      w8, w9
0x1c44256dc mov      w8, #-0x31ee
0x1c44256e0 csel     w20, w8, w20, eq
0x1c44256e4 b        #0x1c4425840
0x1c44256e8 mov      w9, #0x6473
0x1c44256ec movk     w9, #0x6d6a, lsl #16
0x1c44256f0 cmp      w8, w9
0x1c44256f4 b.eq     #0x1c4425864
0x1c44256f8 mov      w9, #0x6174
0x1c44256fc movk     w9, #0x7064, lsl #16
0x1c4425700 cmp      w8, w9
0x1c4425704 b.eq     #0x1c44257f4
0x1c4425708 mov      w9, #0x7365
0x1c442570c movk     w9, #0x7066, lsl #16
0x1c4425710 cmp      w8, w9
0x1c4425714 b.ne     #0x1c4425840
0x1c4425718 mov      x0, x21
0x1c442571c bl       #0x1c4735588
0x1c4425720 b        #0x1c442583c
0x1c4425724 mov      w9, #0x7365
0x1c4425728 movk     w9, #0x6366, lsl #16
0x1c442572c cmp      w8, w9
0x1c4425730 b.ne     #0x1c4425874
0x1c4425734 mov      x0, x23
0x1c4425738 bl       #0x1c4735830
0x1c442573c b        #0x1c442583c
0x1c4425740 mov      w9, #0x7064
0x1c4425744 movk     w9, #0x726e, lsl #16
0x1c4425748 cmp      w8, w9
0x1c442574c b.ne     #0x1c44258a8
0x1c4425750 mov      x0, x22
0x1c4425754 mov      x1, x21
0x1c4425758 bl       #0x1c44268e0
0x1c442575c b        #0x1c442583c
0x1c4425760 mov      x0, x22
0x1c4425764 mov      x1, x21
0x1c4425768 mov      x2, x23
0x1c442576c bl       #0x1c4427384
0x1c4425770 b        #0x1c442583c
0x1c4425774 mov      x0, x22
0x1c4425778 mov      x1, x21
0x1c442577c mov      x2, x23
0x1c4425780 bl       #0x1c4426bd4
0x1c4425784 b        #0x1c442583c
0x1c4425788 mov      x0, x22
0x1c442578c mov      x1, x21
0x1c4425790 bl       #0x1c4426f84
0x1c4425794 b        #0x1c442583c
0x1c4425798 mov      w20, #-0x31ee
0x1c442579c b        #0x1c4425840
0x1c44257a0 mov      x0, x22
0x1c44257a4 mov      x1, x21
0x1c44257a8 bl       #0x1c473526c
0x1c44257ac b        #0x1c442583c
0x1c44257b0 mov      x0, x22
0x1c44257b4 mov      x1, x21
0x1c44257b8 bl       #0x1c4734afc
0x1c44257bc b        #0x1c442583c
0x1c44257c0 mov      x0, x22
0x1c44257c4 mov      x1, x21
0x1c44257c8 bl       #0x1c4735ab0
0x1c44257cc b        #0x1c442583c
0x1c44257d0 mov      x0, x22
0x1c44257d4 mov      x1, x21
0x1c44257d8 mov      x2, x23
0x1c44257dc bl       #0x1c4735894
0x1c44257e0 b        #0x1c442583c
0x1c44257e4 mov      x0, x22
0x1c44257e8 mov      x1, x21
0x1c44257ec bl       #0x1c4735758
0x1c44257f0 b        #0x1c442583c
0x1c44257f4 mov      x0, x22
0x1c44257f8 mov      x1, x21
0x1c44257fc mov      x2, x23
0x1c4425800 bl       #0x1c44598b8
0x1c4425804 b        #0x1c442583c
0x1c4425808 mov      x0, x22
0x1c442580c mov      x1, x21
0x1c4425810 mov      x2, x23
0x1c4425814 bl       #0x1c442f5a0
0x1c4425818 b        #0x1c442583c
0x1c442581c mov      x0, x22
0x1c4425820 mov      x1, x21
0x1c4425824 mov      x2, x23
0x1c4425828 bl       #0x1c44258ec
0x1c442582c b        #0x1c442583c
0x1c4425830 mov      x0, x22
0x1c4425834 mov      x1, x23
0x1c4425838 bl       #0x1c4735164
0x1c442583c mov      x20, x0
0x1c4425840 mov      x0, x19
0x1c4425844 bl       #0x1c49d5578
0x1c4425848 mov      x0, x20
0x1c442584c ldp      x29, x30, [sp, #0x40]
0x1c4425850 ldp      x20, x19, [sp, #0x30]
0x1c4425854 ldp      x22, x21, [sp, #0x20]
0x1c4425858 ldp      x24, x23, [sp, #0x10]
0x1c442585c add      sp, sp, #0x50
0x1c4425860 retab    
0x1c4425864 mov      x0, x23
0x1c4425868 bl       #0x1c4735334
0x1c442586c mov      w20, #0
0x1c4425870 b        #0x1c4425840
0x1c4425874 mov      w9, #0x7064
0x1c4425878 movk     w9, #0x632a, lsl #16
0x1c442587c cmp      w8, w9
0x1c4425880 b.eq     #0x1c44258cc
0x1c4425884 mov      w9, #0x6c6b
0x1c4425888 movk     w9, #0x6363, lsl #16
0x1c442588c cmp      w8, w9
0x1c4425890 b.ne     #0x1c4425840
0x1c4425894 mov      x0, x22
0x1c4425898 mov      x1, x21
0x1c442589c mov      x2, x23
0x1c44258a0 bl       #0x1c447117c
0x1c44258a4 b        #0x1c442583c
0x1c44258a8 mov      w9, #0x7064
0x1c44258ac movk     w9, #0x732a, lsl #16
0x1c44258b0 cmp      w8, w9
0x1c44258b4 b.ne     #0x1c4425840
0x1c44258b8 mov      x0, x22
0x1c44258bc mov      x1, x21
0x1c44258c0 mov      x2, x23
0x1c44258c4 bl       #0x1c498bb94
0x1c44258c8 b        #0x1c442583c
0x1c44258cc mov      x0, x22
0x1c44258d0 mov      x1, x21
0x1c44258d4 mov      x2, x23
0x1c44258d8 bl       #0x1c498b92c
0x1c44258dc b        #0x1c442583c
0x1c44258e0 mov      x20, x0
0x1c44258e4 bl       #0x1c498bfc0
0x1c44258e8 b        #0x1c4425848
0x1c44258ec pacibsp  
0x1c44258f0 stp      x28, x27, [sp, #-0x60]!
0x1c44258f4 stp      x26, x25, [sp, #0x10]
0x1c44258f8 stp      x24, x23, [sp, #0x20]
0x1c44258fc stp      x22, x21, [sp, #0x30]
0x1c4425900 stp      x20, x19, [sp, #0x40]
0x1c4425904 stp      x29, x30, [sp, #0x50]
0x1c4425908 add      x29, sp, #0x50
0x1c442590c sub      sp, sp, #0x340
0x1c4425910 mov      x20, x2
0x1c4425914 mov      x8, x1
0x1c4425918 mov      x28, x0
0x1c442591c adrp     x9, #0x1fe465000
0x1c4425920 ldr      x9, [x9, #0x5b0]
0x1c4425924 ldr      x1, [x9]
0x1c4425928 mov      x0, x8
0x1c442592c bl       #0x1ca1f6d10
0x1c4425930 str      x0, [sp, #0x48]
0x1c4425934 mov      x0, #0
0x1c4425938 mov      x1, #0
0x1c442593c bl       #0x1ca1f6ae0
0x1c4425940 cbz      x0, #0x1c44262a0
0x1c4425944 mov      x22, x0
0x1c4425948 add      x19, sp, #0x120
0x1c442594c movi     v0.2d, #0000000000000000
0x1c4425950 stp      q0, q0, [x19, #0x1f0]
0x1c4425954 sub      x1, x29, #0x80
0x1c4425958 mov      x0, x28
0x1c442595c bl       #0x1ca1f6ba0
0x1c4425960 bl       #0x1c44262b8
0x1c4425964 str      x22, [sp, #0x20]
0x1c4425968 str      x20, [sp, #0x10]
0x1c442596c tbz      w0, #0, #0x1c4425d08
0x1c4425970 ldp      q0, q1, [x19, #0x1f0]
0x1c4425974 stp      q0, q1, [x19, #0x40]
0x1c4425978 add      x0, sp, #0x160
0x1c442597c bl       #0x1c44262c0
0x1c4425980 bl       #0x1ca1f6060
0x1c4425984 mov      x22, x0
0x1c4425988 bl       #0x1c442632c
0x1c442598c cbz      x22, #0x1c4425d14
0x1c4425990 mov      x2, x22
0x1c4425994 bl       #0x1c4d0c7a0
0x1c4425998 cbz      w0, #0x1c4425d14
0x1c442599c adrp     x8, #0x205348000
0x1c44259a0 ldr      x0, [x8, #0x7e0]
0x1c44259a4 bl       #0x1ca1f4280
0x1c44259a8 adrp     x24, #0x203092000
0x1c44259ac ldr      x0, [x24, #0x900]
0x1c44259b0 adrp     x21, #0x205348000
0x1c44259b4 ldr      x2, [x21, #0x7e8]
0x1c44259b8 bl       #0x1c4d07240
0x1c44259bc mov      x25, x0
0x1c44259c0 ldr      x0, [x21, #0x7e8]
0x1c44259c4 adrp     x19, #0x1fe46e000
0x1c44259c8 ldr      x20, [x19, #0xec0]
0x1c44259cc bl       #0x1ca1f1fd0
0x1c44259d0 str      x0, [sp]
0x1c44259d4 adrp     x2, #0x209cac000
0x1c44259d8 add      x2, x2, #0xdb0
0x1c44259dc mov      x0, x20
0x1c44259e0 bl       #0x1c4d446a0
0x1c44259e4 ldr      x0, [x24, #0x900]
0x1c44259e8 ldr      x20, [x19, #0xec0]
0x1c44259ec bl       #0x1c4d0d1c0
0x1c44259f0 str      x0, [sp]
0x1c44259f4 adrp     x2, #0x209cac000
0x1c44259f8 add      x2, x2, #0xdd0
0x1c44259fc mov      x0, x20
0x1c4425a00 bl       #0x1c4d446a0
0x1c4425a04 mov      x0, x25
0x1c4425a08 bl       #0x1c4d0d1c0
0x1c4425a0c cbz      x0, #0x1c4425d20
0x1c4425a10 adrp     x8, #0x1fe461000
0x1c4425a14 ldr      x0, [x8, #0xf70]
0x1c4425a18 bl       #0x1ca1f6050
0x1c4425a1c mov      x23, x0
0x1c4425a20 movi     v0.2d, #0000000000000000
0x1c4425a24 add      x19, sp, #0x120
0x1c4425a28 stp      q0, q0, [x19, #0x1b0]
0x1c4425a2c stp      q0, q0, [x19, #0x1d0]
0x1c4425a30 sub      x2, x29, #0xc0
0x1c4425a34 add      x3, sp, #0x250
0x1c4425a38 str      x25, [sp, #0x40]
0x1c4425a3c mov      x0, x25
0x1c4425a40 mov      w4, #0x10
0x1c4425a44 bl       #0x1c4d0d1e0
0x1c4425a48 cbz      x0, #0x1c4425de0
0x1c4425a4c mov      x27, x0
0x1c4425a50 str      x28, [sp, #0x18]
0x1c4425a54 ldur     x8, [x29, #-0xb0]
0x1c4425a58 adrp     x9, #0x1ff49e000
0x1c4425a5c add      x9, x9, #0x6a0
0x1c4425a60 ldr      x8, [x8]
0x1c4425a64 str      x8, [sp, #0x50]
0x1c4425a68 ldr      x8, [x9]
0x1c4425a6c str      x8, [sp, #0x38]
0x1c4425a70 adrp     x8, #0x1fe462000
0x1c4425a74 ldr      x8, [x8, #0x480]
0x1c4425a78 adrp     x9, #0x1ff49e000
0x1c4425a7c add      x9, x9, #0x770
0x1c4425a80 ldr      x28, [x8]
0x1c4425a84 ldr      x20, [x9]
0x1c4425a88 adrp     x8, #0x1ff49f000
0x1c4425a8c ldr      x9, [x8, #0x118]
0x1c4425a90 adrp     x8, #0x1ff49f000
0x1c4425a94 ldr      x8, [x8, #0x180]
0x1c4425a98 stp      x8, x9, [sp, #0x28]
0x1c4425a9c mov      x24, #0
0x1c4425aa0 ldur     x8, [x29, #-0xb0]
0x1c4425aa4 ldr      x8, [x8]
0x1c4425aa8 ldr      x9, [sp, #0x50]
0x1c4425aac cmp      x8, x9
0x1c4425ab0 b.eq     #0x1c4425abc
0x1c4425ab4 ldr      x0, [sp, #0x40]
0x1c4425ab8 bl       #0x1ca1f60e0
0x1c4425abc ldur     x8, [x29, #-0xb8]
0x1c4425ac0 ldr      x21, [x8, x24, lsl #3]
0x1c4425ac4 str      xzr, [sp, #0x248]
0x1c4425ac8 mov      x0, x21
0x1c4425acc bl       #0x1ca1f2b00
0x1c4425ad0 ldr      x16, [x0, #8]!
0x1c4425ad4 mov      x17, x0
0x1c4425ad8 movk     x17, #0xb911, lsl #48
0x1c4425adc autda    x16, x17
0x1c4425ae0 ldr      x8, [x16, #0x30]!
0x1c4425ae4 cbz      x8, #0x1c4425b34
0x1c4425ae8 mov      x9, x16
0x1c4425aec mov      x16, x8
0x1c4425af0 mov      x17, x9
0x1c4425af4 movk     x17, #0x9725, lsl #48
0x1c4425af8 autia    x16, x17
0x1c4425afc mov      x17, x16
0x1c4425b00 xpaci    x17
0x1c4425b04 cmp      x16, x17
0x1c4425b08 b.eq     #0x1c4425b10
0x1c4425b0c brk      #0xc470
0x1c4425b10 paciza   x16
0x1c4425b14 cbz      x16, #0x1c4425b34
0x1c4425b18 add      x3, sp, #0x248
0x1c4425b1c mov      x0, x21
0x1c4425b20 ldr      x1, [sp, #0x38]
0x1c4425b24 mov      x2, x28
0x1c4425b28 mov      x17, x9
0x1c4425b2c movk     x17, #0x9725, lsl #48
0x1c4425b30 blraa    x8, x17
0x1c4425b34 ldr      x0, [sp, #0x248]
0x1c4425b38 mov      x2, x20
0x1c4425b3c bl       #0x1c4d22800
0x1c4425b40 bl       #0x1c4d1b3e0
0x1c4425b44 mov      x26, x0
0x1c4425b48 ldr      x8, [sp, #0x248]
0x1c4425b4c bl       #0x1ca1f62a0
0x1c4425b50 str      xzr, [sp, #0x240]
0x1c4425b54 mov      x0, x21
0x1c4425b58 bl       #0x1ca1f2b00
0x1c4425b5c ldr      x16, [x0, #8]!
0x1c4425b60 mov      x17, x0
0x1c4425b64 movk     x17, #0xb911, lsl #48
0x1c4425b68 autda    x16, x17
0x1c4425b6c ldr      x8, [x16, #0x30]!
0x1c4425b70 cbz      x8, #0x1c4425bc0
0x1c4425b74 mov      x9, x16
0x1c4425b78 mov      x16, x8
0x1c4425b7c mov      x17, x9
0x1c4425b80 movk     x17, #0x9725, lsl #48
0x1c4425b84 autia    x16, x17
0x1c4425b88 mov      x17, x16
0x1c4425b8c xpaci    x17
0x1c4425b90 cmp      x16, x17
0x1c4425b94 b.eq     #0x1c4425b9c
0x1c4425b98 brk      #0xc470
0x1c4425b9c paciza   x16
0x1c4425ba0 cbz      x16, #0x1c4425bc0
0x1c4425ba4 add      x3, sp, #0x240
0x1c4425ba8 mov      x0, x21
0x1c4425bac ldr      x1, [sp, #0x30]
0x1c4425bb0 mov      x2, x28
0x1c4425bb4 mov      x17, x9
0x1c4425bb8 movk     x17, #0x9725, lsl #48
0x1c4425bbc blraa    x8, x17
0x1c4425bc0 str      xzr, [sp, #0x238]
0x1c4425bc4 mov      x0, x21
0x1c4425bc8 bl       #0x1ca1f2b00
0x1c4425bcc ldr      x16, [x0, #8]!
0x1c4425bd0 mov      x17, x0
0x1c4425bd4 movk     x17, #0xb911, lsl #48
0x1c4425bd8 autda    x16, x17
0x1c4425bdc ldr      x8, [x16, #0x30]!
0x1c4425be0 cbz      x8, #0x1c4425c30
0x1c4425be4 mov      x9, x16
0x1c4425be8 mov      x16, x8
0x1c4425bec mov      x17, x9
0x1c4425bf0 movk     x17, #0x9725, lsl #48
0x1c4425bf4 autia    x16, x17
0x1c4425bf8 mov      x17, x16
0x1c4425bfc xpaci    x17
0x1c4425c00 cmp      x16, x17
0x1c4425c04 b.eq     #0x1c4425c0c
0x1c4425c08 brk      #0xc470
0x1c4425c0c paciza   x16
0x1c4425c10 cbz      x16, #0x1c4425c30
0x1c4425c14 add      x3, sp, #0x238
0x1c4425c18 mov      x0, x21
0x1c4425c1c ldr      x1, [sp, #0x28]
0x1c4425c20 mov      x2, x28
0x1c4425c24 mov      x17, x9
0x1c4425c28 movk     x17, #0x9725, lsl #48
0x1c4425c2c blraa    x8, x17
0x1c4425c30 ldr      x0, [sp, #0x238]
0x1c4425c34 bl       #0x1c4d087c0
0x1c4425c38 mov      x25, x0
0x1c4425c3c ldr      x2, [sp, #0x240]
0x1c4425c40 mov      x0, x22
0x1c4425c44 bl       #0x1c4d1c3e0
0x1c4425c48 cbz      w0, #0x1c4425cc4
0x1c4425c4c cbz      w25, #0x1c4425cc4
0x1c4425c50 ldr      x9, [sp, #0x48]
0x1c4425c54 tst      w9, #2
0x1c4425c58 ccmp     w26, #2, #0, ne
0x1c4425c5c cset     w8, ne
0x1c4425c60 tst      w9, #1
0x1c4425c64 ccmp     w26, #1, #0, ne
0x1c4425c68 b.eq     #0x1c4425c70
0x1c4425c6c tbnz     w8, #0, #0x1c4425cc4
0x1c4425c70 movi     v0.2d, #0000000000000000
0x1c4425c74 stp      q0, q0, [x19, #0xf0]
0x1c4425c78 add      x8, sp, #0x210
0x1c4425c7c mov      x0, x21
0x1c4425c80 bl       #0x1c445b234
0x1c4425c84 ldp      q0, q1, [x19, #0xf0]
0x1c4425c88 stp      q0, q1, [x19, #0x40]
0x1c4425c8c add      x0, sp, #0x160
0x1c4425c90 bl       #0x1c442b174
0x1c4425c94 cbz      w0, #0x1c4425cb8
0x1c4425c98 ldp      q0, q1, [x19, #0x1f0]
0x1c4425c9c stp      q0, q1, [x19, #0x40]
0x1c4425ca0 ldp      q0, q1, [x19, #0xf0]
0x1c4425ca4 stp      q0, q1, [x19, #0xd0]
0x1c4425ca8 add      x0, sp, #0x160
0x1c4425cac add      x1, sp, #0x1f0
0x1c4425cb0 bl       #0x1c445b4ac
0x1c4425cb4 cbnz     w0, #0x1c4425d30
0x1c4425cb8 mov      x0, x23
0x1c4425cbc mov      x2, x21
0x1c4425cc0 bl       #0x1c4d05c40
0x1c4425cc4 ldr      x8, [sp, #0x240]
0x1c4425cc8 bl       #0x1ca1f62a0
0x1c4425ccc add      x24, x24, #1
0x1c4425cd0 cmp      x27, x24
0x1c4425cd4 b.ne     #0x1c4425aa0
0x1c4425cd8 sub      x2, x29, #0xc0
0x1c4425cdc add      x3, sp, #0x250
0x1c4425ce0 ldr      x0, [sp, #0x40]
0x1c4425ce4 mov      w4, #0x10
0x1c4425ce8 bl       #0x1c4d0d1e0
0x1c4425cec mov      x27, x0
0x1c4425cf0 cbnz     x0, #0x1c4425a9c
0x1c4425cf4 mov      w26, #1
0x1c4425cf8 ldr      x28, [sp, #0x18]
0x1c4425cfc adrp     x21, #0x205348000
0x1c4425d00 adrp     x24, #0x203092000
0x1c4425d04 b        #0x1c4425de4
0x1c4425d08 bl       #0x1c442632c
0x1c4425d0c mov      w26, #0
0x1c4425d10 b        #0x1c4425e70
0x1c4425d14 mov      w26, #0
0x1c4425d18 ldr      x22, [sp, #0x20]
0x1c4425d1c b        #0x1c4425e70
0x1c4425d20 mov      w26, #1
0x1c4425d24 add      x19, sp, #0x120
0x1c4425d28 ldr      x22, [sp, #0x20]
0x1c4425d2c b        #0x1c4425e64
0x1c4425d30 adrp     x8, #0x205347000
0x1c4425d34 ldr      w8, [x8, #0xfb0]
0x1c4425d38 ldp      x28, x22, [sp, #0x18]
0x1c4425d3c cbz      w8, #0x1c4425e14
0x1c4425d40 str      wzr, [sp, #0x1ec]
0x1c4425d44 strb     wzr, [sp, #0x1eb]
0x1c4425d48 adrp     x25, #0x205347000
0x1c4425d4c ldr      x0, [x25, #0xfa8]
0x1c4425d50 add      x2, sp, #0x1ec
0x1c4425d54 add      x3, sp, #0x1eb
0x1c4425d58 mov      w1, #1
0x1c4425d5c bl       #0x1ca1f59d0
0x1c4425d60 mov      x20, x0
0x1c4425d64 ldr      w24, [sp, #0x1ec]
0x1c4425d68 ldrb     w21, [sp, #0x1eb]
0x1c4425d6c mov      x1, x21
0x1c4425d70 bl       #0x1ca1f64a0
0x1c4425d74 and      w8, w24, #0xfffffffe
0x1c4425d78 cmp      w0, #0
0x1c4425d7c csel     w0, w24, w8, ne
0x1c4425d80 cbz      w0, #0x1c4425dec
0x1c4425d84 adrp     x8, #0x1c4a0a000
0x1c4425d88 ldr      d0, [x8, #0x330]
0x1c4425d8c str      s0, [sp, #0x1f0]
0x1c4425d90 adrp     x8, #0x1c4bde000
0x1c4425d94 add      x8, x8, #0x410
0x1c4425d98 stur     x8, [x19, #0xd4]
0x1c4425d9c mov      w8, #0xc
0x1c4425da0 str      w8, [sp, #8]
0x1c4425da4 add      x8, sp, #0x1f0
0x1c4425da8 str      x8, [sp]
0x1c4425dac adrp     x4, #0x1c4412000
0x1c4425db0 add      x4, x4, #0
0x1c4425db4 adrp     x7, #0x1c4c24000
0x1c4425db8 add      x7, x7, #0x866
0x1c4425dbc add      x2, sp, #0x160
0x1c4425dc0 mov      x1, #0
0x1c4425dc4 mov      w3, #0x80
0x1c4425dc8 mov      x5, x20
0x1c4425dcc mov      x6, x21
0x1c4425dd0 bl       #0x1ca1f50b0
0x1c4425dd4 mov      x3, x0
0x1c4425dd8 ldr      w24, [sp, #0x1ec]
0x1c4425ddc b        #0x1c4425df0
0x1c4425de0 mov      w26, #1
0x1c4425de4 ldr      x22, [sp, #0x20]
0x1c4425de8 b        #0x1c4425e28
0x1c4425dec mov      x3, #0
0x1c4425df0 ldr      x0, [x25, #0xfa8]
0x1c4425df4 add      x8, sp, #0x160
0x1c4425df8 cmp      x3, x8
0x1c4425dfc cset     w4, ne
0x1c4425e00 mov      w1, #1
0x1c4425e04 mov      w2, #1
0x1c4425e08 mov      x5, x24
0x1c4425e0c mov      x6, #0
0x1c4425e10 bl       #0x1ca1f59c0
0x1c4425e14 mov      x0, x23
0x1c4425e18 bl       #0x1c4d29560
0x1c4425e1c mov      w26, #0
0x1c4425e20 adrp     x21, #0x205348000
0x1c4425e24 adrp     x24, #0x203092000
0x1c4425e28 mov      x0, x23
0x1c4425e2c bl       #0x1c4d0d1c0
0x1c4425e30 cbz      x0, #0x1c4425e60
0x1c4425e34 ldr      x0, [x24, #0x900]
0x1c4425e38 mov      x2, x23
0x1c4425e3c bl       #0x1c4d297e0
0x1c4425e40 ldr      x0, [x21, #0x7e8]
0x1c4425e44 mov      x2, x23
0x1c4425e48 bl       #0x1c4d297e0
0x1c4425e4c adrp     x8, #0x205348000
0x1c4425e50 ldr      x0, [x8, #0x7e0]
0x1c4425e54 bl       #0x1ca1f4290
0x1c4425e58 cbnz     x23, #0x1c4425e98
0x1c4425e5c b        #0x1c4425e70
0x1c4425e60 bl       #0x1ca1f6240
0x1c4425e64 adrp     x8, #0x205348000
0x1c4425e68 ldr      x0, [x8, #0x7e0]
0x1c4425e6c bl       #0x1ca1f4290
0x1c4425e70 ldp      q0, q1, [x19, #0x1f0]
0x1c4425e74 stp      q0, q1, [x19, #0x40]
0x1c4425e78 add      x1, sp, #0x160
0x1c4425e7c ldr      x0, [sp, #0x48]
0x1c4425e80 mov      x2, #0
0x1c4425e84 mov      w3, #1
0x1c4425e88 mov      w4, #0
0x1c4425e8c bl       #0x1c44243fc
0x1c4425e90 mov      x23, x0
0x1c4425e94 cbz      x0, #0x1c44262ac
0x1c4425e98 adrp     x8, #0x205348000
0x1c4425e9c ldr      x0, [x8, #0x7e0]
0x1c4425ea0 bl       #0x1ca1f4280
0x1c4425ea4 cbnz     w0, #0x1c4425ed8
0x1c4425ea8 adrp     x8, #0x205348000
0x1c4425eac ldr      x20, [x8, #0x7e8]
0x1c4425eb0 mov      x0, x23
0x1c4425eb4 bl       #0x1ca1f1fd0
0x1c4425eb8 mov      x3, x0
0x1c4425ebc mov      x0, x20
0x1c4425ec0 mov      x1, x23
0x1c4425ec4 mov      x2, #0
0x1c4425ec8 bl       #0x1ca1f1f50
0x1c4425ecc adrp     x8, #0x205348000
0x1c4425ed0 ldr      x0, [x8, #0x7e0]
0x1c4425ed4 bl       #0x1ca1f4290
0x1c4425ed8 mov      x0, x23
0x1c4425edc bl       #0x1ca1f1fd0
0x1c4425ee0 cmp      x0, #1
0x1c4425ee4 b.lt     #0x1c44261b8
0x1c4425ee8 mov      x24, #0
0x1c4425eec adrp     x8, #0x1ff49f000
0x1c4425ef0 ldr      x8, [x8, #0x180]
0x1c4425ef4 str      x8, [sp, #0x50]
0x1c4425ef8 adrp     x25, #0x203092000
0x1c4425efc str      x28, [sp, #0x18]
0x1c4425f00 str      xzr, [sp, #0x210]
0x1c4425f04 mov      x0, x23
0x1c4425f08 mov      x1, x24
0x1c4425f0c bl       #0x1ca1f2000
0x1c4425f10 mov      x27, x0
0x1c4425f14 cbz      w26, #0x1c44260a4
0x1c4425f18 ldp      q0, q1, [x19, #0x1f0]
0x1c4425f1c stp      q0, q1, [x19, #0x40]
0x1c4425f20 add      x1, sp, #0x160
0x1c4425f24 mov      x0, x27
0x1c4425f28 bl       #0x1c445b308
0x1c4425f2c mov      x0, x27
0x1c4425f30 bl       #0x1ca1f2b00
0x1c4425f34 ldr      x16, [x0, #8]!
0x1c4425f38 mov      x17, x0
0x1c4425f3c movk     x17, #0xb911, lsl #48
0x1c4425f40 autda    x16, x17
0x1c4425f44 ldr      x8, [x16, #0x38]!
0x1c4425f48 cbz      x8, #0x1c4425f98
0x1c4425f4c mov      x9, x16
0x1c4425f50 mov      x16, x8
0x1c4425f54 mov      x17, x9
0x1c4425f58 movk     x17, #0x2724, lsl #48
0x1c4425f5c autia    x16, x17
0x1c4425f60 mov      x17, x16
0x1c4425f64 xpaci    x17
0x1c4425f68 cmp      x16, x17
0x1c4425f6c b.eq     #0x1c4425f74
0x1c4425f70 brk      #0xc470
0x1c4425f74 paciza   x16
0x1c4425f78 cbz      x16, #0x1c4425f98
0x1c4425f7c mov      x0, x27
0x1c4425f80 ldr      x1, [sp, #0x50]
0x1c4425f84 adrp     x2, #0x1fe462000
0x1c4425f88 ldr      x2, [x2, #0x118]
0x1c4425f8c mov      x17, x9
0x1c4425f90 movk     x17, #0x2724, lsl #48
0x1c4425f94 blraa    x8, x17
0x1c4425f98 adrp     x8, #0x205348000
0x1c4425f9c ldr      x0, [x8, #0x7e0]
0x1c4425fa0 bl       #0x1ca1f4280
0x1c4425fa4 cbnz     w0, #0x1c44260a4
0x1c4425fa8 movi     v0.2d, #0000000000000000
0x1c4425fac stp      q0, q0, [x19, #0x20]
0x1c4425fb0 stp      q0, q0, [x19]
0x1c4425fb4 ldr      x0, [x25, #0x908]
0x1c4425fb8 bl       #0x1c4d065c0
0x1c4425fbc mov      x20, x0
0x1c4425fc0 add      x2, sp, #0x120
0x1c4425fc4 add      x3, sp, #0xa0
0x1c4425fc8 mov      w4, #0x10
0x1c4425fcc bl       #0x1c4d0d1e0
0x1c4425fd0 mov      x21, x0
0x1c4425fd4 cbz      x0, #0x1c442607c
0x1c4425fd8 ldr      x8, [sp, #0x130]
0x1c4425fdc ldr      x22, [x8]
0x1c4425fe0 mov      x19, #0
0x1c4425fe4 ldr      x8, [sp, #0x130]
0x1c4425fe8 ldr      x8, [x8]
0x1c4425fec cmp      x8, x22
0x1c4425ff0 b.eq     #0x1c4425ffc
0x1c4425ff4 mov      x0, x20
0x1c4425ff8 bl       #0x1ca1f60e0
0x1c4425ffc ldr      x8, [sp, #0x128]
0x1c4426000 ldr      x28, [x8, x19, lsl #3]
0x1c4426004 ldr      x0, [x25, #0x908]
0x1c4426008 mov      x2, x28
0x1c442600c bl       #0x1c4d22800
0x1c4426010 cmp      x0, x27
0x1c4426014 b.eq     #0x1c4426048
0x1c4426018 add      x19, x19, #1
0x1c442601c cmp      x21, x19
0x1c4426020 b.ne     #0x1c4425fe4
0x1c4426024 add      x2, sp, #0x120
0x1c4426028 add      x3, sp, #0xa0
0x1c442602c mov      x0, x20
0x1c4426030 mov      w4, #0x10
0x1c4426034 bl       #0x1c4d0d1e0
0x1c4426038 mov      x21, x0
0x1c442603c cbnz     x0, #0x1c4425fe0
0x1c4426040 mov      x20, #0
0x1c4426044 b        #0x1c4426070
0x1c4426048 adrp     x8, #0x203092000
0x1c442604c ldr      x0, [x8, #0x910]
0x1c4426050 mov      x2, x28
0x1c4426054 bl       #0x1c4d22800
0x1c4426058 bl       #0x1ca1f62c0
0x1c442605c bl       #0x1ca1f6060
0x1c4426060 mov      x20, x0
0x1c4426064 mov      x0, x28
0x1c4426068 bl       #0x1c4d46d20
0x1c442606c mov      x21, x0
0x1c4426070 ldp      x28, x22, [sp, #0x18]
0x1c4426074 add      x19, sp, #0x120
0x1c4426078 b        #0x1c4426080
0x1c442607c mov      x20, #0
0x1c4426080 adrp     x8, #0x205348000
0x1c4426084 ldr      x0, [x8, #0x7e0]
0x1c4426088 bl       #0x1ca1f4290
0x1c442608c cmp      x21, #0
0x1c4426090 ccmp     x20, #0, #4, ne
0x1c4426094 b.eq     #0x1c44260a4
0x1c4426098 mov      x0, x20
0x1c442609c mov      x1, x21
0x1c44260a0 bl       #0x1ca1f4570
0x1c44260a4 mov      w0, #0x10
0x1c44260a8 mov      w1, #1
0x1c44260ac mov      w2, #0x815c
0x1c44260b0 movk     w2, #0x2e07, lsl #16
0x1c44260b4 bl       #0x1ca1f5ed0
0x1c44260b8 mov      x21, x0
0x1c44260bc stp      x28, x27, [x0]
0x1c44260c0 adrp     x16, #0x1c4735000
0x1c44260c4 add      x16, x16, #0xc98
0x1c44260c8 paciza   x16
0x1c44260cc mov      x3, x16
0x1c44260d0 adrp     x16, #0x1c442b000
0x1c44260d4 add      x16, x16, #0x90c
0x1c44260d8 paciza   x16
0x1c44260dc mov      x4, x16
0x1c44260e0 add      x5, sp, #0x210
0x1c44260e4 mov      x0, x28
0x1c44260e8 mov      x1, x27
0x1c44260ec mov      x2, x21
0x1c44260f0 bl       #0x1ca1f4560
0x1c44260f4 cbnz     w0, #0x1c4426278
0x1c44260f8 str      xzr, [sp, #0x160]
0x1c44260fc ldr      x1, [sp, #0x210]
0x1c4426100 add      x2, sp, #0x160
0x1c4426104 mov      x0, x27
0x1c4426108 bl       #0x1c4423cb4
0x1c442610c cbnz     w0, #0x1c442628c
0x1c4426110 ldr      x20, [sp, #0x160]
0x1c4426114 mov      x0, x22
0x1c4426118 mov      x1, x20
0x1c442611c bl       #0x1ca1f6ac0
0x1c4426120 cbz      w26, #0x1c4426134
0x1c4426124 adrp     x8, #0x205348000
0x1c4426128 ldr      x0, [x8, #0x7e0]
0x1c442612c bl       #0x1ca1f4280
0x1c4426130 cbz      w0, #0x1c4426158
0x1c4426134 cbz      x20, #0x1c4426140
0x1c4426138 mov      x0, x20
0x1c442613c bl       #0x1ca1f2420
0x1c4426140 add      x24, x24, #1
0x1c4426144 mov      x0, x23
0x1c4426148 bl       #0x1ca1f1fd0
0x1c442614c cmp      x0, x24
0x1c4426150 b.gt     #0x1c4425f00
0x1c4426154 b        #0x1c44261b8
0x1c4426158 ldr      x21, [x25, #0x908]
0x1c442615c adrp     x19, #0x1fe46e000
0x1c4426160 ldr      x0, [x19, #0xd98]
0x1c4426164 ldr      x2, [sp, #0x210]
0x1c4426168 bl       #0x1c4d22640
0x1c442616c mov      x3, x0
0x1c4426170 mov      x0, x21
0x1c4426174 mov      x2, x27
0x1c4426178 bl       #0x1c4d37ee0
0x1c442617c adrp     x8, #0x203092000
0x1c4426180 ldr      x21, [x8, #0x910]
0x1c4426184 ldr      x0, [x19, #0xd98]
0x1c4426188 add      x19, sp, #0x120
0x1c442618c ldr      x2, [sp, #0x210]
0x1c4426190 bl       #0x1c4d22640
0x1c4426194 mov      x3, x0
0x1c4426198 mov      x0, x21
0x1c442619c mov      x2, x28
0x1c44261a0 bl       #0x1c4d37ee0
0x1c44261a4 adrp     x8, #0x205348000
0x1c44261a8 ldr      x0, [x8, #0x7e0]
0x1c44261ac bl       #0x1ca1f4290
0x1c44261b0 cbnz     x20, #0x1c4426138
0x1c44261b4 b        #0x1c4426140
0x1c44261b8 adrp     x8, #0x1fe465000
0x1c44261bc ldr      x8, [x8, #0x5c8]
0x1c44261c0 ldr      x1, [x8]
0x1c44261c4 ldr      x0, [sp, #0x10]
0x1c44261c8 mov      x2, x22
0x1c44261cc bl       #0x1ca1f6df0
0x1c44261d0 ldr      x8, [sp, #0x48]
0x1c44261d4 tbz      w8, #0, #0x1c4426240
0x1c44261d8 mov      x0, x23
0x1c44261dc bl       #0x1ca1f2430
0x1c44261e0 adrp     x8, #0x205348000
0x1c44261e4 ldr      x0, [x8, #0x9c8]
0x1c44261e8 add      x8, sp, #0x58
0x1c44261ec adrp     x16, #0x1fe4ed000
0x1c44261f0 ldr      x16, [x16, #0x820]
0x1c44261f4 mov      x17, x8
0x1c44261f8 movk     x17, #0x6ae1, lsl #48
0x1c44261fc pacda    x16, x17
0x1c4426200 str      x16, [sp, #0x58]
0x1c4426204 adrp     x9, #0x1c4a0a000
0x1c4426208 ldr      d0, [x9, #0x1e0]
0x1c442620c str      d0, [sp, #0x60]
0x1c4426210 add      x8, x8, #0x10
0x1c4426214 adrp     x16, #0x1c4431000
0x1c4426218 add      x16, x16, #0xf24
0x1c442621c pacia    x16, x8
0x1c4426220 adrp     x8, #0x1ff4a0000
0x1c4426224 add      x8, x8, #0xb68
0x1c4426228 ldp      q0, q1, [x19, #0x1f0]
0x1c442622c stp      q0, q1, [sp, #0x80]
0x1c4426230 stp      x16, x8, [sp, #0x68]
0x1c4426234 str      x23, [sp, #0x78]
0x1c4426238 add      x1, sp, #0x58
0x1c442623c bl       #0x1c49d4788
0x1c4426240 mov      w20, #0
0x1c4426244 mov      x0, x23
0x1c4426248 bl       #0x1ca1f2420
0x1c442624c mov      x0, x22
0x1c4426250 bl       #0x1ca1f2420
0x1c4426254 mov      x0, x20
0x1c4426258 add      sp, sp, #0x340
0x1c442625c ldp      x29, x30, [sp, #0x50]
0x1c4426260 ldp      x20, x19, [sp, #0x40]
0x1c4426264 ldp      x22, x21, [sp, #0x30]
0x1c4426268 ldp      x24, x23, [sp, #0x20]
0x1c442626c ldp      x26, x25, [sp, #0x10]
0x1c4426270 ldp      x28, x27, [sp], #0x60
0x1c4426274 retab    
0x1c4426278 mov      x20, x0
0x1c442627c add      x2, sp, #0x210
0x1c4426280 mov      x1, x21
0x1c4426284 bl       #0x1c498c588
0x1c4426288 b        #0x1c4426244
0x1c442628c mov      x20, x0
0x1c4426290 add      x1, sp, #0x160
0x1c4426294 add      x2, sp, #0x210
0x1c4426298 bl       #0x1c498c600
0x1c442629c b        #0x1c4426244
0x1c44262a0 bl       #0x1c498c6c0
0x1c44262a4 mov      w20, #-0x31f2
0x1c44262a8 b        #0x1c4426254
0x1c44262ac bl       #0x1c498c660
0x1c44262b0 mov      w20, #-0x31ef
0x1c44262b4 b        #0x1c442624c
0x1c44262b8 mov      w0, #1
0x1c44262bc ret      
0x1c44262c0 pacibsp  
0x1c44262c4 sub      sp, sp, #0x40
0x1c44262c8 stp      x20, x19, [sp, #0x20]
0x1c44262cc stp      x29, x30, [sp, #0x30]
0x1c44262d0 add      x29, sp, #0x30
0x1c44262d4 adrp     x8, #0x1fe462000
0x1c44262d8 ldr      x8, [x8, #0x480]
0x1c44262dc ldr      x8, [x8]
0x1c44262e0 ldp      q0, q1, [x0]
0x1c44262e4 stp      q0, q1, [sp]
0x1c44262e8 mov      x1, sp
0x1c44262ec mov      x0, x8
0x1c44262f0 bl       #0x1ca1f4c30
0x1c44262f4 cbz      x0, #0x1c4426314
0x1c44262f8 mov      x19, x0
0x1c44262fc mov      x1, #0
0x1c4426300 bl       #0x1ca1f4c00
0x1c4426304 mov      x20, x0
0x1c4426308 mov      x0, x19
0x1c442630c bl       #0x1ca1f2420
0x1c4426310 b        #0x1c4426318
0x1c4426314 mov      x20, #0
0x1c4426318 mov      x0, x20
0x1c442631c ldp      x29, x30, [sp, #0x30]
0x1c4426320 ldp      x20, x19, [sp, #0x20]
0x1c4426324 add      sp, sp, #0x40
0x1c4426328 retab    
0x1c442632c adrp     x8, #0x203092000
0x1c4426330 ldr      x8, [x8, #0xb08]
0x1c4426334 cmn      x8, #1
0x1c4426338 b.ne     #0x1c4426348
0x1c442633c adrp     x8, #0x203092000
0x1c4426340 ldr      x0, [x8, #0xb10]
0x1c4426344 ret      
0x1c4426348 pacibsp  
0x1c442634c stp      x29, x30, [sp, #-0x10]!
0x1c4426350 mov      x29, sp
0x1c4426354 bl       #0x1c49caae8
0x1c4426358 ldp      x29, x30, [sp], #0x10
0x1c442635c autibsp  
0x1c4426360 b        #0x1c442633c
0x1c4426364 pacibsp  
0x1c4426368 sub      sp, sp, #0x90
0x1c442636c stp      x22, x21, [sp, #0x60]
0x1c4426370 stp      x20, x19, [sp, #0x70]
0x1c4426374 stp      x29, x30, [sp, #0x80]
0x1c4426378 add      x29, sp, #0x80
0x1c442637c mov      x19, x3
0x1c4426380 mov      x22, x2
0x1c4426384 mov      x20, x0
0x1c4426388 stur     xzr, [x29, #-0x28]
0x1c442638c adrp     x8, #0x205348000
0x1c4426390 ldr      x8, [x8, #0xa90]
0x1c4426394 cmn      x8, #1
0x1c4426398 b.ne     #0x1c4426500
0x1c442639c bl       #0x1c442509c
0x1c44263a0 mov      x2, x0
0x1c44263a4 adrp     x1, #0x209c6a000
0x1c44263a8 add      x1, x1, #0x840
0x1c44263ac sub      x3, x29, #0x28
0x1c44263b0 mov      x0, x20
0x1c44263b4 bl       #0x1ca1f2bc0
0x1c44263b8 mov      x20, x0
0x1c44263bc cbnz     w0, #0x1c4426508
0x1c44263c0 ldur     x0, [x29, #-0x28]
0x1c44263c4 bl       #0x1ca1f2af0
0x1c44263c8 mov      x21, x0
0x1c44263cc ldp      q1, q0, [x22]
0x1c44263d0 stp      q1, q0, [x0, #0x10]
0x1c44263d4 ldp      q0, q1, [x0, #0x10]
0x1c44263d8 stp      q0, q1, [sp, #0x30]
0x1c44263dc add      x0, sp, #0x30
0x1c44263e0 bl       #0x1c442b174
0x1c44263e4 cbz      w0, #0x1c44263fc
0x1c44263e8 ldp      q0, q1, [x21, #0x10]
0x1c44263ec stp      q0, q1, [sp, #0x30]
0x1c44263f0 add      x0, sp, #0x30
0x1c44263f4 bl       #0x1c44262c0
0x1c44263f8 str      x0, [x21, #0x48]
0x1c44263fc adrp     x1, #0x205348000
0x1c4426400 add      x1, x1, #0x8e8
0x1c4426404 mov      w22, #1
0x1c4426408 mov      w0, #1
0x1c442640c bl       #0x1ca1f3950
0x1c4426410 sxtw     x8, w0
0x1c4426414 str      x8, [x21]
0x1c4426418 bl       #0x1ca1f4250
0x1c442641c str      x0, [x21, #0x30]
0x1c4426420 adrp     x0, #0x1c4be5000
0x1c4426424 add      x0, x0, #0xec4
0x1c4426428 mov      x1, #0
0x1c442642c mov      w2, #0
0x1c4426430 bl       #0x1ca1f3de0
0x1c4426434 str      x0, [x21, #0x38]
0x1c4426438 mov      w8, #5
0x1c442643c str      w8, [x21, #8]
0x1c4426440 adrp     x8, #0x1ff48d000
0x1c4426444 ldr      x0, [x8, #0x9e0]
0x1c4426448 ldur     x2, [x29, #-0x28]
0x1c442644c bl       #0x1c4d48e80
0x1c4426450 add      x8, sp, #8
0x1c4426454 adrp     x16, #0x1fe4ed000
0x1c4426458 ldr      x16, [x16, #0x820]
0x1c442645c mov      x17, x8
0x1c4426460 movk     x17, #0x6ae1, lsl #48
0x1c4426464 pacda    x16, x17
0x1c4426468 str      x16, [sp, #8]
0x1c442646c adrp     x9, #0x1c4a0a000
0x1c4426470 ldr      d0, [x9, #0x1e0]
0x1c4426474 str      d0, [sp, #0x10]
0x1c4426478 add      x8, x8, #0x10
0x1c442647c adrp     x16, #0x1c4752000
0x1c4426480 add      x16, x16, #0x284
0x1c4426484 pacia    x16, x8
0x1c4426488 adrp     x8, #0x1ff49f000
0x1c442648c add      x8, x8, #0x778
0x1c4426490 stp      x16, x8, [sp, #0x18]
0x1c4426494 str      x0, [sp, #0x28]
0x1c4426498 bl       #0x1ca1f4250
0x1c442649c str      x0, [x21, #0xc8]
0x1c44264a0 adrp     x8, #0x20533f000
0x1c44264a4 add      x0, x8, #0x540
0x1c44264a8 bl       #0x1ca1f6040
0x1c44264ac add      x2, sp, #8
0x1c44264b0 bl       #0x1c4d177e0
0x1c44264b4 str      x0, [x21, #0xd0]
0x1c44264b8 strb     w22, [x21, #0xd]
0x1c44264bc adrp     x21, #0x205348000
0x1c44264c0 ldr      x0, [x21, #0x9f0]
0x1c44264c4 bl       #0x1ca1f4280
0x1c44264c8 adrp     x8, #0x205348000
0x1c44264cc ldr      x0, [x8, #0x9f8]
0x1c44264d0 ldur     x2, [x29, #-0x28]
0x1c44264d4 bl       #0x1c4d05c40
0x1c44264d8 ldr      x0, [x21, #0x9f0]
0x1c44264dc bl       #0x1ca1f4290
0x1c44264e0 ldur     x8, [x29, #-0x28]
0x1c44264e4 str      x8, [x19]
0x1c44264e8 mov      x0, x20
0x1c44264ec ldp      x29, x30, [sp, #0x80]
0x1c44264f0 ldp      x20, x19, [sp, #0x70]
0x1c44264f4 ldp      x22, x21, [sp, #0x60]
0x1c44264f8 add      sp, sp, #0x90
0x1c44264fc retab    
0x1c4426500 bl       #0x1c49adb5c
0x1c4426504 b        #0x1c442639c
0x1c4426508 sub      x1, x29, #0x28
0x1c442650c mov      x0, x20
0x1c4426510 bl       #0x1c49ae058
0x1c4426514 b        #0x1c44264e8
0x1c4426518 adrp     x0, #0x205349000
0x1c442651c add      x0, x0, #0x2f8
0x1c4426520 adrp     x1, #0x209c6c000
0x1c4426524 add      x1, x1, #0x290
0x1c4426528 b        #0x1c49d4868
0x1c442652c pacibsp  
0x1c4426530 stp      x29, x30, [sp, #-0x10]!
0x1c4426534 mov      x29, sp
0x1c4426538 bl       #0x1ca1f2ae0
0x1c442653c mov      x1, x0
0x1c4426540 adrp     x0, #0x209c6a000
0x1c4426544 add      x0, x0, #0x270
0x1c4426548 adrp     x3, #0x205349000
0x1c442654c add      x3, x3, #0x2e0
0x1c4426550 mov      w2, #1
0x1c4426554 ldp      x29, x30, [sp], #0x10
0x1c4426558 autibsp  
0x1c442655c eor      x16, x30, x30, lsl #1
0x1c4426560 tbz      x16, #0x3e, #0x1c4426568
0x1c4426564 brk      #0xc471
0x1c4426568 b        #0x1ca1f39c0
0x1c442656c pacibsp  
0x1c4426570 sub      sp, sp, #0x40
0x1c4426574 stp      x22, x21, [sp, #0x10]
0x1c4426578 stp      x20, x19, [sp, #0x20]
0x1c442657c stp      x29, x30, [sp, #0x30]
0x1c4426580 add      x29, sp, #0x30
0x1c4426584 mov      x19, x1
0x1c4426588 str      xzr, [sp, #8]
0x1c442658c add      x2, sp, #8
0x1c4426590 mov      w1, #0x7064
0x1c4426594 movk     w1, #0x726e, lsl #16
0x1c4426598 bl       #0x1c442662c
0x1c442659c adrp     x21, #0x205349000
0x1c44265a0 cbnz     w0, #0x1c4426608
0x1c44265a4 ldr      x0, [sp, #8]
0x1c44265a8 adrp     x8, #0x20308c000
0x1c44265ac ldr      x1, [x8, #0xbc8]
0x1c44265b0 mov      x2, x19
0x1c44265b4 bl       #0x1ca1f4480
0x1c44265b8 cbnz     w0, #0x1c4426614
0x1c44265bc ldr      x0, [x21, #0x2c8]
0x1c44265c0 ldr      x1, [sp, #8]
0x1c44265c4 bl       #0x1ca1f4500
0x1c44265c8 mov      x20, x0
0x1c44265cc cbnz     w0, #0x1c4426620
0x1c44265d0 ldr      x0, [sp, #8]
0x1c44265d4 bl       #0x1ca1f44a0
0x1c44265d8 ldr      x0, [x21, #0x2c8]
0x1c44265dc adrp     x2, #0x1c4b72000
0x1c44265e0 add      x2, x2, #0x2f
0x1c44265e4 mov      x1, x20
0x1c44265e8 mov      x3, x19
0x1c44265ec bl       #0x1ca1f44e0
0x1c44265f0 mov      x0, x20
0x1c44265f4 ldp      x29, x30, [sp, #0x30]
0x1c44265f8 ldp      x20, x19, [sp, #0x20]
0x1c44265fc ldp      x22, x21, [sp, #0x10]
0x1c4426600 add      sp, sp, #0x40
0x1c4426604 retab    
0x1c4426608 mov      x20, x0
0x1c442660c bl       #0x1c47d5dd4
0x1c4426610 b        #0x1c44265d0
0x1c4426614 mov      x20, x0
0x1c4426618 bl       #0x1c47d5e4c
0x1c442661c b        #0x1c44265d0
0x1c4426620 mov      x0, x20
0x1c4426624 bl       #0x1c47d5ec4
0x1c4426628 b        #0x1c44265d0
0x1c442662c pacibsp  
0x1c4426630 sub      sp, sp, #0x40
0x1c4426634 stp      x22, x21, [sp, #0x10]
0x1c4426638 stp      x20, x19, [sp, #0x20]
0x1c442663c stp      x29, x30, [sp, #0x30]
0x1c4426640 add      x29, sp, #0x30
0x1c4426644 stp      xzr, xzr, [sp]
0x1c4426648 cbz      x2, #0x1c4426698
0x1c442664c mov      x19, x2
0x1c4426650 mov      x21, x1
0x1c4426654 mov      x1, sp
0x1c4426658 bl       #0x1c442752c
0x1c442665c cbnz     w0, #0x1c44266a4
0x1c4426660 ldr      x1, [sp]
0x1c4426664 add      x2, sp, #8
0x1c4426668 mov      x0, x21
0x1c442666c bl       #0x1ca1f4340
0x1c4426670 mov      x20, x0
0x1c4426674 cbnz     w0, #0x1c44266b0
0x1c4426678 ldr      x8, [sp, #8]
0x1c442667c str      x8, [x19]
0x1c4426680 mov      x0, x20
0x1c4426684 ldp      x29, x30, [sp, #0x30]
0x1c4426688 ldp      x20, x19, [sp, #0x20]
0x1c442668c ldp      x22, x21, [sp, #0x10]
0x1c4426690 add      sp, sp, #0x40
0x1c4426694 retab    
0x1c4426698 bl       #0x1c442792c
0x1c442669c mov      w20, #-0x31ec
0x1c44266a0 b        #0x1c4426680
0x1c44266a4 mov      x20, x0
0x1c44266a8 bl       #0x1c47d55ec
0x1c44266ac b        #0x1c4426680
0x1c44266b0 mov      x0, x20
0x1c44266b4 bl       #0x1c47d5664
0x1c44266b8 b        #0x1c4426680
0x1c44266bc pacibsp  
0x1c44266c0 sub      sp, sp, #0x60
0x1c44266c4 stp      x24, x23, [sp, #0x20]
0x1c44266c8 stp      x22, x21, [sp, #0x30]
0x1c44266cc stp      x20, x19, [sp, #0x40]
0x1c44266d0 stp      x29, x30, [sp, #0x50]
0x1c44266d4 add      x29, sp, #0x50
0x1c44266d8 mov      x19, x1
0x1c44266dc stp      xzr, xzr, [sp, #0x10]
0x1c44266e0 adrp     x23, #0x205349000
0x1c44266e4 cbz      x2, #0x1c44267e0
0x1c44266e8 mov      x20, x2
0x1c44266ec add      x2, sp, #0x18
0x1c44266f0 mov      w1, #0x7064
0x1c44266f4 movk     w1, #0x6370, lsl #16
0x1c44266f8 bl       #0x1c442662c
0x1c44266fc cbnz     w0, #0x1c44267e8
0x1c4426700 ldr      x0, [sp, #0x18]
0x1c4426704 adrp     x8, #0x20308c000
0x1c4426708 ldr      x1, [x8, #0xbc8]
0x1c442670c mov      x2, x19
0x1c4426710 bl       #0x1ca1f4480
0x1c4426714 cbnz     w0, #0x1c44267f4
0x1c4426718 ldr      x0, [x23, #0x2c8]
0x1c442671c ldr      x1, [sp, #0x18]
0x1c4426720 add      x2, sp, #0x10
0x1c4426724 bl       #0x1ca1f4510
0x1c4426728 cbnz     w0, #0x1c4426800
0x1c442672c ldr      x8, [sp, #0x10]
0x1c4426730 cbz      x8, #0x1c442680c
0x1c4426734 bl       #0x1ca1f6080
0x1c4426738 mov      x22, x0
0x1c442673c str      xzr, [sp, #8]
0x1c4426740 ldr      x0, [sp, #0x10]
0x1c4426744 adrp     x8, #0x20308c000
0x1c4426748 ldr      x1, [x8, #0xbd0]
0x1c442674c add      x2, sp, #8
0x1c4426750 bl       #0x1ca1f43c0
0x1c4426754 mov      x21, x0
0x1c4426758 ldr      x0, [sp, #8]
0x1c442675c cbz      x0, #0x1c4426780
0x1c4426760 adrp     x8, #0x1fe462000
0x1c4426764 ldr      x8, [x8, #0x738]
0x1c4426768 ldr      x1, [x8]
0x1c442676c bl       #0x1ca1f2210
0x1c4426770 cbz      w0, #0x1c4426788
0x1c4426774 mov      x8, #0
0x1c4426778 str      xzr, [sp, #8]
0x1c442677c b        #0x1c442678c
0x1c4426780 mov      x8, #0
0x1c4426784 b        #0x1c442678c
0x1c4426788 ldr      x8, [sp, #8]
0x1c442678c str      x8, [x20]
0x1c4426790 cbnz     w21, #0x1c4426818
0x1c4426794 mov      x0, x22
0x1c4426798 bl       #0x1c49d5578
0x1c442679c ldr      x0, [sp, #0x18]
0x1c44267a0 bl       #0x1ca1f44a0
0x1c44267a4 ldr      x0, [sp, #0x10]
0x1c44267a8 bl       #0x1ca1f44a0
0x1c44267ac ldr      x0, [x23, #0x2c8]
0x1c44267b0 adrp     x2, #0x1c4b71000
0x1c44267b4 add      x2, x2, #0xfda
0x1c44267b8 mov      x1, x21
0x1c44267bc mov      x3, x19
0x1c44267c0 bl       #0x1ca1f44e0
0x1c44267c4 mov      x0, x21
0x1c44267c8 ldp      x29, x30, [sp, #0x50]
0x1c44267cc ldp      x20, x19, [sp, #0x40]
0x1c44267d0 ldp      x22, x21, [sp, #0x30]
0x1c44267d4 ldp      x24, x23, [sp, #0x20]
0x1c44267d8 add      sp, sp, #0x60
0x1c44267dc retab    
0x1c44267e0 bl       #0x1c47d5b7c
0x1c44267e4 b        #0x1c4426810
0x1c44267e8 mov      x21, x0
0x1c44267ec bl       #0x1c47d5924
0x1c44267f0 b        #0x1c442679c
0x1c44267f4 mov      x21, x0
0x1c44267f8 bl       #0x1c47d599c
0x1c44267fc b        #0x1c442679c
0x1c4426800 mov      x21, x0
0x1c4426804 bl       #0x1c47d5a14
0x1c4426808 b        #0x1c442679c
0x1c442680c bl       #0x1c47d5b04
0x1c4426810 mov      w21, #0
0x1c4426814 b        #0x1c442679c
0x1c4426818 mov      x0, x21
0x1c442681c bl       #0x1c47d5a8c
0x1c4426820 b        #0x1c4426794
0x1c4426824 pacibsp  
0x1c4426828 sub      sp, sp, #0x30
0x1c442682c stp      x20, x19, [sp, #0x10]
0x1c4426830 stp      x29, x30, [sp, #0x20]
0x1c4426834 add      x29, sp, #0x20
0x1c4426838 mov      x19, x2
0x1c442683c mov      x8, x1
0x1c4426840 mov      x20, x0
0x1c4426844 adrp     x9, #0x1fe465000
0x1c4426848 ldr      x9, [x9, #0x5a0]
0x1c442684c ldr      x1, [x9]
0x1c4426850 mov      x0, x8
0x1c4426854 bl       #0x1ca1f6d40
0x1c4426858 mov      x1, x0
0x1c442685c str      xzr, [sp, #8]
0x1c4426860 add      x2, sp, #8
0x1c4426864 mov      x0, x20
0x1c4426868 mov      x3, #0
0x1c442686c bl       #0x1ca1f4590
0x1c4426870 cbnz     w0, #0x1c44268b0
0x1c4426874 ldr      x0, [sp, #8]
0x1c4426878 cbz      x0, #0x1c44268bc
0x1c442687c bl       #0x1ca1f2260
0x1c4426880 mov      x20, x0
0x1c4426884 bl       #0x1c44274e4
0x1c4426888 cmp      x20, x0
0x1c442688c b.ne     #0x1c44268c8
0x1c4426890 mov      w20, #0
0x1c4426894 ldr      x8, [sp, #8]
0x1c4426898 str      x8, [x19]
0x1c442689c mov      x0, x20
0x1c44268a0 ldp      x29, x30, [sp, #0x20]
0x1c44268a4 ldp      x20, x19, [sp, #0x10]
0x1c44268a8 add      sp, sp, #0x30
0x1c44268ac retab    
0x1c44268b0 mov      x20, x0
0x1c44268b4 bl       #0x1c498da40
0x1c44268b8 b        #0x1c44268d0
0x1c44268bc bl       #0x1c498db00
0x1c44268c0 mov      w20, #-0x31ef
0x1c44268c4 b        #0x1c44268d0
0x1c44268c8 bl       #0x1c498daa0
0x1c44268cc mov      w20, #-0x31ec
0x1c44268d0 ldr      x0, [sp, #8]
0x1c44268d4 cbz      x0, #0x1c442689c
0x1c44268d8 bl       #0x1ca1f2420
0x1c44268dc b        #0x1c442689c
0x1c44268e0 pacibsp  
0x1c44268e4 sub      sp, sp, #0x30
0x1c44268e8 stp      x20, x19, [sp, #0x10]
0x1c44268ec stp      x29, x30, [sp, #0x20]
0x1c44268f0 add      x29, sp, #0x20
0x1c44268f4 mov      x20, x1
0x1c44268f8 stp      xzr, xzr, [sp]
0x1c44268fc add      x2, sp, #8
0x1c4426900 bl       #0x1c4426824
0x1c4426904 cbnz     w0, #0x1c44269d8
0x1c4426908 adrp     x8, #0x20308c000
0x1c442690c ldr      x1, [x8, #0xbc8]
0x1c4426910 mov      x2, sp
0x1c4426914 mov      x0, x20
0x1c4426918 bl       #0x1ca1f43d0
0x1c442691c cbnz     w0, #0x1c44269e4
0x1c4426920 ldp      x20, x19, [sp]
0x1c4426924 mov      x0, x19
0x1c4426928 bl       #0x1ca1f2b00
0x1c442692c ldr      x16, [x0, #0x10]!
0x1c4426930 mov      x17, x0
0x1c4426934 movk     x17, #0x8446, lsl #48
0x1c4426938 autda    x16, x17
0x1c442693c ldr      x9, [x16]
0x1c4426940 cmp      x9, #2
0x1c4426944 b.lo     #0x1c44269c8
0x1c4426948 mov      x8, x16
0x1c442694c ldr      x9, [x8, #0x30]!
0x1c4426950 cbz      x9, #0x1c44269c8
0x1c4426954 mov      x16, x9
0x1c4426958 mov      x17, x8
0x1c442695c movk     x17, #0x232d, lsl #48
0x1c4426960 autia    x16, x17
0x1c4426964 mov      x17, x16
0x1c4426968 xpaci    x17
0x1c442696c cmp      x16, x17
0x1c4426970 b.eq     #0x1c4426978
0x1c4426974 brk      #0xc470
0x1c4426978 paciza   x16
0x1c442697c cbz      x16, #0x1c44269c8
0x1c4426980 mov      x0, x19
0x1c4426984 mov      x1, x20
0x1c4426988 mov      x17, x8
0x1c442698c movk     x17, #0x232d, lsl #48
0x1c4426990 blraa    x9, x17
0x1c4426994 mov      x19, x0
0x1c4426998 cbnz     w0, #0x1c44269cc
0x1c442699c ldr      x0, [sp, #8]
0x1c44269a0 cbz      x0, #0x1c44269a8
0x1c44269a4 bl       #0x1ca1f2420
0x1c44269a8 ldr      x0, [sp]
0x1c44269ac cbz      x0, #0x1c44269b4
0x1c44269b0 bl       #0x1ca1f2420
0x1c44269b4 mov      x0, x19
0x1c44269b8 ldp      x29, x30, [sp, #0x20]
0x1c44269bc ldp      x20, x19, [sp, #0x10]
0x1c44269c0 add      sp, sp, #0x30
0x1c44269c4 retab    
0x1c44269c8 mov      w19, #-0x31ee
0x1c44269cc mov      x0, x19
0x1c44269d0 bl       #0x1c498cf48
0x1c44269d4 b        #0x1c442699c
0x1c44269d8 mov      x19, x0
0x1c44269dc bl       #0x1c498ce88
0x1c44269e0 b        #0x1c442699c
0x1c44269e4 mov      x19, x0
0x1c44269e8 bl       #0x1c498cee8
0x1c44269ec b        #0x1c442699c
0x1c44269f0 pacibsp  
0x1c44269f4 sub      sp, sp, #0x40
0x1c44269f8 stp      x22, x21, [sp, #0x10]
0x1c44269fc stp      x20, x19, [sp, #0x20]
0x1c4426a00 stp      x29, x30, [sp, #0x30]
0x1c4426a04 add      x29, sp, #0x30
0x1c4426a08 mov      x21, x30
0x1c4426a0c mov      x19, x1
0x1c4426a10 bl       #0x1ca1f2af0
0x1c4426a14 ldrb     w8, [x0, #0xc]
0x1c4426a18 cbz      w8, #0x1c4426a68
0x1c4426a1c adrp     x8, #0x205348000
0x1c4426a20 ldr      x1, [x8, #0x28]
0x1c4426a24 mov      x5, x21
0x1c4426a28 xpaci    x5
0x1c4426a2c adrp     x0, #0x1c4b5b000
0x1c4426a30 add      x0, x0, #0x41a
0x1c4426a34 adrp     x3, #0x1c4be6000
0x1c4426a38 add      x3, x3, #0x4a9
0x1c4426a3c mov      w2, #-0x31f1
0x1c4426a40 mov      w4, #0x17aa
0x1c4426a44 ldp      x29, x30, [sp, #0x30]
0x1c4426a48 ldp      x20, x19, [sp, #0x20]
0x1c4426a4c ldp      x22, x21, [sp, #0x10]
0x1c4426a50 add      sp, sp, #0x40
0x1c4426a54 autibsp  
0x1c4426a58 eor      x16, x30, x30, lsl #1
0x1c4426a5c tbz      x16, #0x3e, #0x1c4426a64
0x1c4426a60 brk      #0xc471
0x1c4426a64 b        #0x1ca1f4220
0x1c4426a68 cbz      x19, #0x1c4426ab4
0x1c4426a6c mov      x20, x0
0x1c4426a70 ldr      x0, [x0, #0xc8]
0x1c4426a74 bl       #0x1ca1f4280
0x1c4426a78 ldr      x8, [x20, #0xd0]
0x1c4426a7c bl       #0x1ca1f6400
0x1c4426a80 mov      x21, x0
0x1c4426a84 ldr      x0, [x20, #0xc8]
0x1c4426a88 bl       #0x1ca1f4290
0x1c4426a8c mov      x0, x21
0x1c4426a90 mov      x2, x19
0x1c4426a94 bl       #0x1c4d22900
0x1c4426a98 bl       #0x1ca1f6220
0x1c4426a9c mov      w0, #0
0x1c4426aa0 ldp      x29, x30, [sp, #0x30]
0x1c4426aa4 ldp      x20, x19, [sp, #0x20]
0x1c4426aa8 ldp      x22, x21, [sp, #0x10]
0x1c4426aac add      sp, sp, #0x40
0x1c4426ab0 retab    
0x1c4426ab4 add      x0, sp, #0xc
0x1c4426ab8 bl       #0x1c49b25f0
0x1c4426abc ldr      w0, [sp, #0xc]
0x1c4426ac0 b        #0x1c4426aa0
0x1c4426ac4 pacibsp  
0x1c4426ac8 sub      sp, sp, #0x40
0x1c4426acc stp      x22, x21, [sp, #0x10]
0x1c4426ad0 stp      x20, x19, [sp, #0x20]
0x1c4426ad4 stp      x29, x30, [sp, #0x30]
0x1c4426ad8 add      x29, sp, #0x30
0x1c4426adc mov      x19, x2
0x1c4426ae0 mov      x21, x0
0x1c4426ae4 stp      xzr, xzr, [sp]
0x1c4426ae8 bl       #0x1c4424334
0x1c4426aec cbnz     w0, #0x1c4426bb0
0x1c4426af0 add      x2, sp, #8
0x1c4426af4 mov      x0, x21
0x1c4426af8 mov      w1, #0x646f
0x1c4426afc movk     w1, #0x6368, lsl #16
0x1c4426b00 bl       #0x1c442662c
0x1c4426b04 cbnz     w0, #0x1c4426bbc
0x1c4426b08 adrp     x8, #0x205349000
0x1c4426b0c ldr      x0, [x8, #0x2c8]
0x1c4426b10 ldr      x1, [sp, #8]
0x1c4426b14 mov      x2, sp
0x1c4426b18 bl       #0x1ca1f4510
0x1c4426b1c cbnz     w0, #0x1c4426bc8
0x1c4426b20 ldr      x0, [sp]
0x1c4426b24 cbz      x0, #0x1c4426b54
0x1c4426b28 bl       #0x1ca1f6e20
0x1c4426b2c adrp     x8, #0x1fe4ed000
0x1c4426b30 ldr      x8, [x8, #0xe98]
0x1c4426b34 cmp      x0, x8
0x1c4426b38 b.eq     #0x1c4426b54
0x1c4426b3c adrp     x8, #0x1fe4ed000
0x1c4426b40 ldr      x8, [x8, #0xe80]
0x1c4426b44 cmp      x0, x8
0x1c4426b48 b.eq     #0x1c4426b80
0x1c4426b4c mov      w20, #0
0x1c4426b50 b        #0x1c4426b58
0x1c4426b54 mov      w20, #-1
0x1c4426b58 ldr      x0, [sp, #8]
0x1c4426b5c bl       #0x1ca1f44a0
0x1c4426b60 ldr      x0, [sp]
0x1c4426b64 bl       #0x1ca1f44a0
0x1c4426b68 mov      x0, x20
0x1c4426b6c ldp      x29, x30, [sp, #0x30]
0x1c4426b70 ldp      x20, x19, [sp, #0x20]
0x1c4426b74 ldp      x22, x21, [sp, #0x10]
0x1c4426b78 add      sp, sp, #0x40
0x1c4426b7c retab    
0x1c4426b80 ldr      x0, [sp]
0x1c4426b84 adrp     x8, #0x20308c000
0x1c4426b88 ldr      x1, [x8, #0xc00]
0x1c4426b8c bl       #0x1ca1f6d10
0x1c4426b90 mov      x20, x0
0x1c4426b94 cbnz     w20, #0x1c4426b58
0x1c4426b98 ldr      x0, [sp]
0x1c4426b9c adrp     x8, #0x20308c000
0x1c4426ba0 ldr      x1, [x8, #0xbd0]
0x1c4426ba4 mov      x2, x19
0x1c4426ba8 bl       #0x1ca1f4370
0x1c4426bac b        #0x1c4426b58
0x1c4426bb0 mov      x20, x0
0x1c4426bb4 bl       #0x1c47d65cc
0x1c4426bb8 b        #0x1c4426b58
0x1c4426bbc mov      x20, x0
0x1c4426bc0 bl       #0x1c47d6644
0x1c4426bc4 b        #0x1c4426b58
0x1c4426bc8 mov      x20, x0
0x1c4426bcc bl       #0x1c47d66bc
0x1c4426bd0 b        #0x1c4426b58
0x1c4426bd4 pacibsp  
0x1c4426bd8 sub      sp, sp, #0x120
0x1c4426bdc stp      x28, x27, [sp, #0xd0]
0x1c4426be0 stp      x24, x23, [sp, #0xe0]
0x1c4426be4 stp      x22, x21, [sp, #0xf0]
0x1c4426be8 stp      x20, x19, [sp, #0x100]
0x1c4426bec stp      x29, x30, [sp, #0x110]
0x1c4426bf0 add      x29, sp, #0x110
0x1c4426bf4 mov      x20, x2
0x1c4426bf8 mov      x19, x1
0x1c4426bfc mov      x22, x0
0x1c4426c00 stp      xzr, xzr, [x29, #-0x50]
0x1c4426c04 bl       #0x1ca1f6bb0
0x1c4426c08 mov      x21, x0
0x1c4426c0c sub      x2, x29, #0x48
0x1c4426c10 mov      x0, x22
0x1c4426c14 mov      x1, x19
0x1c4426c18 bl       #0x1c4426824
0x1c4426c1c cbnz     w0, #0x1c4426e18
0x1c4426c20 ldur     x19, [x29, #-0x48]
0x1c4426c24 mov      x0, x19
0x1c4426c28 bl       #0x1ca1f2b00
0x1c4426c2c ldr      x16, [x0, #0x10]!
0x1c4426c30 mov      x17, x0
0x1c4426c34 movk     x17, #0x8446, lsl #48
