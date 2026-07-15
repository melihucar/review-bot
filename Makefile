.PHONY: app build run test clean dmg

app:
	./scripts/build-app.sh

dmg: app
	./scripts/build-dmg.sh $(VERSION)

build:
	swift build

run:
	swift run ReviewBot

test:
	swift test

clean:
	swift package clean
