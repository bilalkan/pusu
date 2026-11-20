.PHONY: build debug run test icon install uninstall package clean

build:
	scripts/build.sh release

debug:
	scripts/build.sh debug

run: debug
	open build/Pusu.app

test:
	swift run PusuTests

icon:
	scripts/make-icons.sh

install:
	scripts/install.sh

uninstall:
	scripts/uninstall.sh

package: test
	scripts/package.sh

clean:
	rm -rf .build build dist
