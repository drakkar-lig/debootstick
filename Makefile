# avoid dpkg-dev dependency; fish out the version with sed
VERSION := $(shell sed 's/.*(\(.*\)).*/\1/; q' debian/changelog)

all:

clean:

ifdef DH_BUILD_TYPE
# debhelper will manage installation of docs itself
install: install-tool

uninstall: uninstall-tool

else
install: install-tool install-docs

uninstall: uninstall-tool uninstall-docs

endif

DSDIR=$(DESTDIR)/usr/share/debootstick
install-tool:
	set -e
	mkdir -p $(DSDIR)/scripts $(DSDIR)/disk-layouts
	mkdir -p $(DESTDIR)/usr/sbin

	cp -ar scripts/* $(DSDIR)/scripts/
	cp -ar disk-layouts/* $(DSDIR)/disk-layouts/

	sed 's/@VERSION@/$(VERSION)/g' debootstick >$(DESTDIR)/usr/sbin/debootstick
	[ "$(DH_BUILD_TYPE)" = "1" ] || chown root:root $(DESTDIR)/usr/sbin/debootstick
	chmod 0755 $(DESTDIR)/usr/sbin/debootstick

install-docs:
	mkdir -p /usr/share/doc/debootstick
	gzip < debootstick.8 > $(DESTDIR)/usr/share/man/man8/debootstick.8.gz
	gzip < debian/changelog > $(DESTDIR)/usr/share/doc/debootstick/changelog.gz
	cp README.md debian/copyright $(DESTDIR)/usr/share/doc/debootstick/

uninstall-tool:
	rm -Rf $(DSDIR)
	rm $(DESTDIR)/usr/sbin/debootstick

uninstall-docs:
	rm $(DESTDIR)/usr/share/man/man8/debootstick.8.gz
	rm -Rf $(DESTDIR)/usr/share/doc/debootstick/

