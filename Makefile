# swift-testing ships with Xcode. With Command Line Tools only, the framework
# and its interop dylib must be pointed at explicitly or `swift test` fails
# first with "no such module 'Testing'" and then on @rpath/lib_TestingInterop.dylib.
CLT_FW  := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT_FW) \
              -Xlinker -F -Xlinker $(CLT_FW) \
              -Xlinker -rpath -Xlinker $(CLT_FW) \
              -Xlinker -rpath -Xlinker $(CLT_LIB)

.PHONY: build test test-only app run install dmg pkg icon clean

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

# Copies the bundle into /Applications, which is where launch at login needs it
# to live. DEST=~/Applications installs for this user only.
install: app
	./Scripts/install.sh

# Distributable images. Neither is notarised, so a receiving Mac needs one
# manual step; both scripts say which.
dmg: app
	./Scripts/make-dmg.sh

pkg: app
	./Scripts/make-pkg.sh

# Only after changing the icon's geometry. Commit Resources/AppIcon.icns.
icon:
	./Scripts/make-icon.sh

clean:
	rm -rf .build Claudence.app Claudence-*.dmg Claudence-*.pkg
