# swift-testing ships with Xcode. With Command Line Tools only, the framework
# and its interop dylib must be pointed at explicitly or `swift test` fails
# first with "no such module 'Testing'" and then on @rpath/lib_TestingInterop.dylib.
CLT_FW  := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT_FW) \
              -Xlinker -F -Xlinker $(CLT_FW) \
              -Xlinker -rpath -Xlinker $(CLT_FW) \
              -Xlinker -rpath -Xlinker $(CLT_LIB)

.PHONY: build test app run clean

build:
	swift build

test:
	DYLD_FRAMEWORK_PATH=$(CLT_FW) DYLD_LIBRARY_PATH=$(CLT_LIB) swift test $(TEST_FLAGS)

# make test-only FILTER=RegistryTests
test-only:
	DYLD_FRAMEWORK_PATH=$(CLT_FW) DYLD_LIBRARY_PATH=$(CLT_LIB) swift test $(TEST_FLAGS) --filter $(FILTER)

app:
	./Scripts/make-app.sh

run: app
	open Claudence.app

clean:
	rm -rf .build Claudence.app
