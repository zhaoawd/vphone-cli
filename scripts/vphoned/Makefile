# vphoned — iOS guest daemon (cross-compiled for arm64 iphoneos)

SRCS := $(wildcard *.m)
OUT  := vphoned

# Passed from parent Makefile
GIT_HASH ?= unknown
EXTRA_CFLAGS ?=
IOS_DEPLOYMENT_TARGET ?= 15.0

.PHONY: all clean

all: $(OUT)

$(OUT): $(SRCS) $(wildcard *.h)
	@echo "=== Building vphoned (arm64, iphoneos) ==="
	xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=$(IOS_DEPLOYMENT_TARGET) -Os -fobjc-arc $(EXTRA_CFLAGS) \
		-I. \
		-Ivendor/libarchive \
		-DVPHONED_BUILD_HASH='"$(GIT_HASH)"' \
		-o $@ $(SRCS) \
		-larchive \
		-lsqlite3 \
		-framework Foundation \
		-framework Security \
		-framework CoreServices
	@echo "  built OK"

clean:
	rm -f $(OUT)
