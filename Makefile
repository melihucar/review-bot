.PHONY: app build run test clean

app:
	./scripts/build-app.sh

build:
	swift build

run:
	swift run ReviewBot

test:
	swift test

clean:
	swift package clean
