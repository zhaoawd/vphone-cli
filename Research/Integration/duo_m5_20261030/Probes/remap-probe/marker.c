// Keep the remapped function independent of globals, literals and other code.
__attribute__((noinline, used, visibility("default"), aligned(16384)))
int MARKER_NAME(void) { return MARKER_VALUE; }
