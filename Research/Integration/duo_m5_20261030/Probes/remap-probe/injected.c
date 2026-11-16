static int initialized;
__attribute__((constructor)) static void initialize(void) { initialized = 1; }
int remap_injection_ready(void) { return initialized; }
int remap_injection_answer(void) { return 73; }
