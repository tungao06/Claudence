.PHONY: build app test clean run

build:
	swift build

test:
	swift test

app:
	./Scripts/make-app.sh

run: app
	open Claudence.app

clean:
	rm -rf .build Claudence.app
