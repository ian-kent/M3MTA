all:
	@- echo "Use 'make install' to install M3MTA"

stop:
	@- if [ -e "/var/run/m3mta/imap.pid" ]; then /etc/init.d/m3mta-imap stop; fi
	@- if [ -e "/var/run/m3mta/smtp.pid" ]; then /etc/init.d/m3mta-smtp stop; fi
	@- if [ -e "/var/run/m3mta/mda.pid" ]; then /etc/init.d/m3mta-mda stop; fi

start:
	@- if [ ! -e "/var/run/m3mta/imap.pid" ]; then /etc/init.d/m3mta-imap start; fi
	@- if [ ! -e "/var/run/m3mta/smtp.pid" ]; then /etc/init.d/m3mta-smtp start; fi
	@- if [ ! -e "/var/run/m3mta/mda.pid" ]; then /etc/init.d/m3mta-mda start; fi

restart: stop start

clean:
	@- if [ -e "/var/run/m3mta/imap.pid" ]; then /etc/init.d/m3mta-imap stop; fi
	@- if [ -e "/var/run/m3mta/smtp.pid" ]; then /etc/init.d/m3mta-smtp stop; fi
	@- if [ -e "/var/run/m3mta/mda.pid" ]; then /etc/init.d/m3mta-mda stop; fi
	@- rm /usr/bin/m3mta-imap
	@- rm /usr/bin/m3mta-smtp
	@- rm /usr/bin/m3mta-mda
	@- rm /usr/bin/m3mta
	@- rm /etc/init.d/m3mta-imap
	@- rm /etc/init.d/m3mta-smtp
	@- rm /etc/init.d/m3mta-mda
	@- rm -rf /usr/lib/m3mta
	@- rm -rf /var/run/m3mta
	@ echo "Config files in /etc/m3mta not removed, run 'make remove-config'"
	@ echo "Log files in /var/log/m3mta not removed, run 'make remove-logs'"

remove-config:
	@- rm -rf /etc/m3mta
	@ echo "Config files in /etc/m3mta have been removed"

remove-logs:
	@- rm -rf /var/log/m3mta
	@ echo "Log files in /var/log/m3mta have been removed"

install:
	@ mkdir /usr/lib/m3mta
	@ cp -r ./lib/* /usr/lib/m3mta
	@ cp ./bin/m3mta-imap /usr/bin/m3mta-imap
	@ cp ./bin/m3mta-smtp /usr/bin/m3mta-smtp
	@ cp ./bin/m3mta-mda /usr/bin/m3mta-mda
	@ cp ./bin/m3mta /usr/bin/m3mta
	@ cp ./init.d/m3mta-imap /etc/init.d/m3mta-imap
	@ cp ./init.d/m3mta-smtp /etc/init.d/m3mta-smtp
	@ cp ./init.d/m3mta-mda /etc/init.d/m3mta-mda
	@ mkdir /var/run/m3mta
	@ if [ ! -e "/etc/m3mta" ]; then mkdir /etc/m3mta; cp ./etc/* /etc/m3mta/; fi
	@ if [ ! -e "/var/log/m3mta" ]; then mkdir /var/log/m3mta; fi
	@ echo "M3MTA has been installed"

update: stop clean install start