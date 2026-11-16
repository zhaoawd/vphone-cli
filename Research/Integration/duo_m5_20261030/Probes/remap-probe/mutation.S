.section __TEXT,__mutation,regular,pure_instructions
.p2align 14
.globl _mutation_marker
_mutation_marker:
    mov w0, #42
    ret
    nop
    nop
.globl _mutation_replacement
_mutation_replacement:
    mov w0, #91
    ret
.globl _mutation_hook_template
_mutation_hook_template:
    ldr x16, 1f
    br x16
1:  .quad 0
// Keep dyld stubs outside the page whose execute permission the probe changes.
.p2align 14
