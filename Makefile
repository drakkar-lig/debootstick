# avoid dpkg-dev dependency; fish out the version with sed
VERSION := $(shell sed 's/.*(\(.*\)).*/\1/; q' debian/changelog)

all:

clean:

DSDIR=$(DESTDIR)/usr/share/debootstick
install:
	mkdir -p $(DSDIR)/scripts
	mkdir -p $(DESTDIR)/usr/sbin

	cp -ar scripts/* $(DSDIR)/scripts/

	sed 's/@VERSION@/$(VERSION)/g' debootstick >$(DESTDIR)/usr/sbin/debootstick
	chown root:root $(DESTDIR)/usr/sbin/debootstick
	chmod 0755 $(DESTDIR)/usr/sbin/debootstick

