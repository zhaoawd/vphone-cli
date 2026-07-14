# libvcamcaptured — dylib loaded into cameracaptured via LC_LOAD_DYLIB

SRCS := $(wildcard *.m)
OUT  := libvcamcaptured.dylib
LDID ?= ldid

.PHONY: all clean

all: $(OUT)

$(OUT): $(SRCS) $(wildcard *.h)
	@echo "=== Building libvcamcaptured (arm64e, iphoneos, dylib) ==="
	xcrun -sdk iphoneos clang -arch arm64e -Os -fobjc-arc \
		-dynamiclib \
		-install_name /var/jb/usr/lib/libvcamcaptured.dylib \
		-I. \
		-o $@ $(SRCS) \
		-framework Foundation \
		-framework CoreMedia \
		-framework CoreVideo
	$(LDID) -S $@
	@echo "  built OK ($$(stat -f%z $(OUT)) bytes)"

clean:
	rm -f $(OUT)
