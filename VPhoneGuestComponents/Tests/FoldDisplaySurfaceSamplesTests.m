#import <Foundation/Foundation.h>
#include "../FoldDisplay/FoldDisplaySurfaceSamples.h"

int main(void) {
    @autoreleasepool {
        // Padding is deliberately bright; it must not enter the pixel grid.
        uint8_t storage[16 * 80];
        memset(storage, 255, sizeof(storage));
        for (size_t y = 0; y < 16; y++) for (size_t x = 0; x < 16; x++) {
            uint8_t *p = storage + y * 80 + x * 4;
            p[0] = p[1] = p[2] = 0; p[3] = 255;
        }
        VPhoneFoldSurfaceSamples black = vpFoldSampleBGRA(storage, 16, 16, 80, sizeof(storage));
        NSCAssert(black.valid && black.count == 64 && black.maxRGB == 0 && black.minAlpha == 255, @"opaque black with padded rows");
        storage[1 * 80 + 1 * 4 + 1] = 42;
        NSCAssert(vpFoldSampleBGRA(storage, 16, 16, 80, sizeof(storage)).maxRGB == 42, @"sampled nonblack pixel");
        memset(storage, 0, sizeof(storage));
        VPhoneFoldSurfaceSamples transparent = vpFoldSampleBGRA(storage, 16, 16, 80, sizeof(storage));
        NSCAssert(transparent.valid && transparent.minAlpha == 0 && transparent.maxAlpha == 0, @"transparent zero is distinct from opaque black");
        NSCAssert(!vpFoldSampleBGRA(NULL, 16, 16, 80, sizeof(storage)).valid, @"missing pixels are unavailable");
        NSCAssert(!vpFoldSampleBGRA(storage, 0, 16, 80, sizeof(storage)).valid, @"zero bounds");
        NSCAssert(!vpFoldSampleBGRA(storage, SIZE_MAX, 16, 80, sizeof(storage)).valid, @"width overflow");
        NSCAssert(!vpFoldSampleBGRA(storage, 16, 16, 63, sizeof(storage)).valid, @"short stride");
        NSCAssert(!vpFoldSampleBGRA(storage, 16, 16, 80, sizeof(storage) - 1).valid, @"short allocation");
        uint8_t one[] = {1, 2, 3, 4};
        VPhoneFoldSurfaceSamples tiny = vpFoldSampleBGRA(one, 1, 1, 4, sizeof(one));
        NSCAssert(tiny.valid && tiny.maxRGB == 3 && tiny.minAlpha == 4 && tiny.count == 64, @"small surfaces stay within bounds");
        puts("FoldDisplay surface samples: 9 checks passed");
    }
}
