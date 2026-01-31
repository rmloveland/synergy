# Synergy Makefile

EXE := synergy
VERSION := $(shell git describe --tags --abbrev=0)
ZIPFILE := synergy-$(VERSION).zip

# Define the list of files for distribution
DIST_FILES := $(EXE) inf-synergy.el README.pod README.html Makefile MANIFEST CHANGELOG t/01_synergy_e2e.t t/data/20250313-perl-number-triangle.xml t/data/20250609-sqlchecker-use-random-database.xml

# The MANIFEST file itself is part of DIST_FILES, but its content is
# derived from other DIST_FILES (excluding itself initially) For
# checksum, we list the core source files that define the
# distribution.  README.html and MANIFEST are generated, so they are
# not checksummed directly from source control.
MANIFEST_SOURCES := inf-synergy.el Makefile README.pod README.html $(EXE) t/01_synergy_e2e.t t/data/20250313-perl-number-triangle.xml t/data/20250609-sqlchecker-use-random-database.xml

all: test install

readme: podcheck
	@podselect $(EXE) > README.pod

readme-html: readme
	@pod2html README.pod > README.html

install:
	@mkdir -p $$HOME/bin && \
	cp $(EXE) $$HOME/bin/$(EXE) && \
	chmod 755 $$HOME/bin/$(EXE)

lint:
	@perl -wc $(EXE)

critique:
	@perlcritic $(EXE)

podcheck:
	@podchecker $(EXE)

bat:
	@pl2bat $(EXE)

# On Windows, try `(setq server-use-tcp t)`
winstall: bat
	cp $(EXE).bat $(HOME)/bin/

manifest: checksum

checksum: clean readme-html
	@shasum $(MANIFEST_SOURCES) > MANIFEST

changelog:
	git log --oneline --format="%h %ad %s" --date=short | grep -viE "(chats|dumps|tidy|todo)" > CHANGELOG

clean:
	@rm -f *{~,.elc,.bat,.bak,.html,.zip,.tmp} MANIFEST README.pod README.html CHANGELOG || true

test:
	prove

dist: test tarball

tarball: clean readme-html manifest changelog
	@zip -q $(ZIPFILE) $(DIST_FILES)

# eof
