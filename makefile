all:
	@- echo "Use 'make install' to install M3MTA"

clean:
	@- /usr/bin/m3mta stop
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
	@ mkdir /etc/m3mta
	@ cp ./config.json /etc/m3mta/config.json
	@ mkdir /var/log/m3mta
	@ mkdir /var/run/m3mta
	@ echo "M3MTA has been installed"
