# vim:set ft=dockerfile:
FROM ubuntu:latest

RUN apt-get update
RUN apt-get install -y --no-install-recommends gnupg dirmngr bzip2 unzip xz-utils ca-certificates p11-kit fontconfig libfreetype6 wget libnss-wrapper sudo
RUN rm -rf /var/lib/apt/lists/*

RUN set -eux; \
	groupadd -r postgres --gid=999; \
	useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres; \
	usermod -aG sudo postgres; \
	mkdir -p /var/lib/postgresql; \
	chown -R postgres:postgres /var/lib/postgresql; \
	echo '%sudo	ALL=NOPASSWD: ALL' >> /etc/sudoers; \
	echo 'Defaults        env_keep += "JAVA_HOME"' >> /etc/sudoers

RUN mkdir ~/.gnupg
RUN echo "disable-ipv6" >> ~/.gnupg/dirmngr.conf

# grab gosu for easy step-down from root
ENV GOSU_VERSION 1.11
RUN set -x \
	&& apt-get update && apt-get install -y --no-install-recommends ca-certificates gnupg libnss-wrapper wget && rm -rf /var/lib/apt/lists/* \
	&& wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$(dpkg --print-architecture)" \
	&& wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$(dpkg --print-architecture).asc" \
	&& export GNUPGHOME="$(mktemp -d)" \
	&& for keyserver in $(shuf -e \
			ha.pool.sks-keyservers.net \
			hkp://p80.pool.sks-keyservers.net:80 \
			keyserver.ubuntu.com \
			hkp://keyserver.ubuntu.com:80 \
			pgp.mit.edu) ; do \
		gpg --keyserver $keyserver --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 && break || true ; \
	done \
	&& gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu \
	&& { command -v gpgconf > /dev/null && gpgconf --kill all || :; } \
	&& rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc \
	&& chmod +x /usr/local/bin/gosu \
	&& gosu nobody true \
	&& apt-get purge -y --auto-remove ca-certificates wget

RUN apt-get update
RUN apt-get install -y --no-install-recommends gnupg dirmngr bzip2 unzip xz-utils ca-certificates p11-kit fontconfig libfreetype6 wget libnss-wrapper
RUN rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME /usr/local/openjdk-8
ENV PATH $JAVA_HOME/bin:$PATH

# backwards compatibility shim
RUN { echo '#/bin/sh'; echo 'echo "$JAVA_HOME"'; } > /usr/local/bin/docker-java-home && chmod +x /usr/local/bin/docker-java-home && [ "$JAVA_HOME" = "$(docker-java-home)" ]

# https://adoptopenjdk.net/upstream.html
ENV JAVA_VERSION 8u212-b04
ENV JAVA_BASE_URL https://github.com/AdoptOpenJDK/openjdk8-upstream-binaries/releases/download/jdk8u212-b04/OpenJDK8U-
ENV JAVA_URL_VERSION 8u212b04

RUN set -eux && dpkgArch="$(dpkg --print-architecture)" && case "$dpkgArch" in amd64) upstreamArch='x64' ;; arm64) upstreamArch='aarch64' ;; *) echo >&2 "error: unsupported architecture: $dpkgArch" ;; esac && wget -O openjdk.tgz.asc "${JAVA_BASE_URL}${upstreamArch}_linux_${JAVA_URL_VERSION}.tar.gz.sign" && wget -O openjdk.tgz "${JAVA_BASE_URL}${upstreamArch}_linux_${JAVA_URL_VERSION}.tar.gz" --progress=dot:giga;

RUN export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys CA5F11C6CE22644D42C6AC4492EF8D39DC13168F; \
	gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys EAC843EBD3EFDB98CC772FADA5CD6035332FA671; \
	gpg --batch --list-sigs --keyid-format 0xLONG CA5F11C6CE22644D42C6AC4492EF8D39DC13168F | grep '0xA5CD6035332FA671' | grep 'Andrew Haley'; \
	gpg --batch --verify openjdk.tgz.asc openjdk.tgz; \
	gpgconf --kill all; \
	rm -rf "$GNUPGHOME"; \
	\
	mkdir -p "$JAVA_HOME"; \
	tar --extract \
		--file openjdk.tgz \
		--directory "$JAVA_HOME" \
		--strip-components 1 \
		--no-same-owner \
	; \
	rm openjdk.tgz*; \
	\
	{ \
		echo '#!/usr/bin/env bash'; \
		echo 'set -Eeuo pipefail'; \
		echo 'if ! [ -d "$JAVA_HOME" ]; then echo >&2 "error: missing JAVA_HOME environment variable"; exit 1; fi'; \
# 8-jdk uses "$JAVA_HOME/jre/lib/security/cacerts" and 8-jre and 11+ uses "$JAVA_HOME/lib/security/cacerts" directly (no "jre" directory)
		echo 'cacertsFile=; for f in "$JAVA_HOME/lib/security/cacerts" "$JAVA_HOME/jre/lib/security/cacerts"; do if [ -e "$f" ]; then cacertsFile="$f"; break; fi; done'; \
		echo 'if [ -z "$cacertsFile" ] || ! [ -f "$cacertsFile" ]; then echo >&2 "error: failed to find cacerts file in $JAVA_HOME"; exit 1; fi'; \
		echo 'trust extract --overwrite --format=java-cacerts --filter=ca-anchors --purpose=server-auth "$cacertsFile"'; \
	} > /etc/ca-certificates/update.d/docker-openjdk; \
	chmod +x /etc/ca-certificates/update.d/docker-openjdk; \
	/etc/ca-certificates/update.d/docker-openjdk; \
	\
	find "$JAVA_HOME/lib" -name '*.so' -exec dirname '{}' ';' | sort -u > /etc/ld.so.conf.d/docker-openjdk.conf; \
	ldconfig; \
	\
# basic smoke test
	javac -version; \
	java -version

RUN set -ex; \
	if ! command -v gpg > /dev/null; then \
		apt-get update; \
		apt-get install -y --no-install-recommends \
			gnupg \
			dirmngr \
		; \
		rm -rf /var/lib/apt/lists/*; \
	fi


# make the "en_US.UTF-8" locale so postgres will be utf-8 enabled by default
RUN set -eux; \
	if [ -f /etc/dpkg/dpkg.cfg.d/docker ]; then \
# if this file exists, we're likely in "debian:xxx-slim", and locales are thus being excluded so we need to remove that exclusion (since we need locales)
		grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \
		sed -ri '/\/usr\/share\/locale/d' /etc/dpkg/dpkg.cfg.d/docker; \
		! grep -q '/usr/share/locale' /etc/dpkg/dpkg.cfg.d/docker; \
	fi; \
	apt-get update; apt-get install -y locales; rm -rf /var/lib/apt/lists/*; \
	localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG en_US.utf8

# install "nss_wrapper" in case we need to fake "/etc/passwd" and "/etc/group" (especially for OpenShift)
# https://github.com/docker-library/postgres/issues/359
# https://cwrap.org/nss_wrapper.html
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends libnss-wrapper sudo; \
	rm -rf /var/lib/apt/lists/*

RUN mkdir /docker-entrypoint-initdb.d

RUN set -ex; \
# pub   4096R/ACCC4CF8 2011-10-13 [expires: 2019-07-02]
#       Key fingerprint = B97B 0AFC AA1A 47F0 44F2  44A0 7FCC 7D46 ACCC 4CF8
# uid                  PostgreSQL Debian Repository
	key='B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8'; \
	export GNUPGHOME="$(mktemp -d)"; \
	for keyserver in $(shuf -e \
			ha.pool.sks-keyservers.net \
			hkp://p80.pool.sks-keyservers.net:80 \
			keyserver.ubuntu.com \
			hkp://keyserver.ubuntu.com:80 \
			pgp.mit.edu) ; do \
		gpg --keyserver $keyserver --recv-keys "$key" && break || true ; \
	done; \
	gpg --batch --export "$key" > /etc/apt/trusted.gpg.d/postgres.gpg; \
	command -v gpgconf > /dev/null && gpgconf --kill all; \
	rm -rf "$GNUPGHOME"; \
	apt-key list

ENV PG_MAJOR 9.6
ENV PG_VERSION 9.6.15-1.pgdg90+1

RUN set -ex; \
	\
# see note below about "*.pyc" files
	export PYTHONDONTWRITEBYTECODE=1; \
	\
	dpkgArch="$(dpkg --print-architecture)"; \
	case "$dpkgArch" in \
		amd64|i386|ppc64el) \
# arches officialy built by upstream
			echo "deb http://apt.postgresql.org/pub/repos/apt/ stretch-pgdg main $PG_MAJOR" > /etc/apt/sources.list.d/pgdg.list; \
			apt-get update; \
			;; \
		*) \
# we're on an architecture upstream doesn't officially build for
# let's build binaries from their published source packages
			echo "deb-src http://apt.postgresql.org/pub/repos/apt/ stretch-pgdg main $PG_MAJOR" > /etc/apt/sources.list.d/pgdg.list; \
			\
			case "$PG_MAJOR" in \
				9.* | 10 ) ;; \
				*) \
# https://github.com/docker-library/postgres/issues/484 (clang-6.0 required, only available in stretch-backports)
# TODO remove this once we hit buster+
					echo 'deb http://deb.debian.org/debian stretch-backports main' >> /etc/apt/sources.list.d/pgdg.list; \
					;; \
			esac; \
			\
			tempDir="$(mktemp -d)"; \
			cd "$tempDir"; \
			\
			savedAptMark="$(apt-mark showmanual)"; \
			\
# build .deb files from upstream's source packages (which are verified by apt-get)
			apt-get update; \
			apt-get build-dep -y \
				postgresql-common pgdg-keyring \
				"postgresql-$PG_MAJOR=$PG_VERSION" \
			; \
			DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" \
				apt-get source --compile \
					postgresql-common pgdg-keyring \
					"postgresql-$PG_MAJOR=$PG_VERSION" \
			; \
# we don't remove APT lists here because they get re-downloaded and removed later
			\
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
# (which is done after we install the built packages so we don't have to redownload any overlapping dependencies)
			apt-mark showmanual | xargs apt-mark auto > /dev/null; \
			apt-mark manual $savedAptMark; \
			\
# create a temporary local APT repo to install from (so that dependency resolution can be handled by APT, as it should be)
			ls -lAFh; \
			dpkg-scanpackages . > Packages; \
			grep '^Package: ' Packages; \
			echo "deb [ trusted=yes ] file://$tempDir ./" > /etc/apt/sources.list.d/temp.list; \
# work around the following APT issue by using "Acquire::GzipIndexes=false" (overriding "/etc/apt/apt.conf.d/docker-gzip-indexes")
#   Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
#   ...
#   E: Failed to fetch store:/var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages  Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
			apt-get -o Acquire::GzipIndexes=false update; \
			;; \
	esac; \
	\
	apt-get install -y postgresql-common; \
	sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf; \
	apt-get install -y \
		"postgresql-$PG_MAJOR=$PG_VERSION" \
		"postgresql-contrib-$PG_MAJOR=$PG_VERSION" \
	; \
	\
	rm -rf /var/lib/apt/lists/*; \
	\
	if [ -n "$tempDir" ]; then \
# if we have leftovers from building, let's purge them (including extra, unnecessary build deps)
		apt-get purge -y --auto-remove; \
		rm -rf "$tempDir" /etc/apt/sources.list.d/temp.list; \
	fi; \
	\
# some of the steps above generate a lot of "*.pyc" files (and setting "PYTHONDONTWRITEBYTECODE" beforehand doesn't propagate properly for some reason), so we clean them up manually (as long as they aren't owned by a package)
	find /usr -name '*.pyc' -type f -exec bash -c 'for pyc; do dpkg -S "$pyc" &> /dev/null || rm -vf "$pyc"; done' -- '{}' +

# make the sample config easier to munge (and "correct by default")
RUN set -eux; \
	dpkg-divert --add --rename --divert "/usr/share/postgresql/postgresql.conf.sample.dpkg" "/usr/share/postgresql/$PG_MAJOR/postgresql.conf.sample"; \
	cp -v /usr/share/postgresql/postgresql.conf.sample.dpkg /usr/share/postgresql/postgresql.conf.sample; \
	ln -sv ../postgresql.conf.sample "/usr/share/postgresql/$PG_MAJOR/"; \
	sed -ri "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" /usr/share/postgresql/postgresql.conf.sample; \
	grep -F "listen_addresses = '*'" /usr/share/postgresql/postgresql.conf.sample

RUN mkdir -p /var/run/postgresql && chown -R postgres:postgres /var/run/postgresql && chmod 2777 /var/run/postgresql

RUN apt-get update
RUN apt-get install -y --no-install-recommends gnupg dirmngr bzip2 unzip xz-utils ca-certificates p11-kit fontconfig libfreetype6 wget libnss-wrapper sudo

ENV PATH $PATH:/usr/lib/postgresql/$PG_MAJOR/bin

RUN echo export JAVA_HOME="$JAVA_HOME" >> /etc/profile
RUN echo export PATH="$PATH":'$PATH' >> /etc/profile
RUN echo 'export PATH=$JAVA_HOME/bin:$PATH' >> /etc/profile
RUN echo alias java="$JAVA_HOME"/bin/java >> /etc/profile
RUN cat /etc/profile
RUN /bin/bash -c "source /etc/profile"

RUN echo export JAVA_HOME="$JAVA_HOME" >> ~/.bash_profile
RUN echo export PATH="$PATH":'$PATH' >> ~/.bash_profile
RUN echo 'export PATH=$JAVA_HOME/bin:$PATH' >> ~/.bash_profile
RUN echo alias java="$JAVA_HOME"/bin/java >> ~/.bash_profile
RUN cat ~/.bash_profile
RUN /bin/bash -c "source ~/.bash_profile"

RUN echo export JAVA_HOME="$JAVA_HOME" >> /etc/bashrc
RUN echo export PATH="$PATH":'$PATH' >> /etc/bashrc
RUN echo 'export PATH=$JAVA_HOME/bin:$PATH' >> /etc/bashrc
RUN echo alias java="$JAVA_HOME"/bin/java >> /etc/bashrc
RUN cat /etc/bashrc
RUN /bin/bash -c "source /etc/bashrc"

RUN echo JAVA_HOME="$JAVA_HOME" >> /etc/environment
RUN /bin/bash -c "source /etc/environment"

RUN echo 'Defaults        secure_path += "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:'"$JAVA_HOME"'/bin"' >> /etc/sudoers

RUN cat /etc/sudoers

ENV PGDATA /var/lib/postgresql/data
# this 777 will be replaced by 700 at runtime (allows semi-arbitrary "--user" values)
RUN mkdir -p "$PGDATA" && chown -R postgres:postgres "$PGDATA" && chmod 777 "$PGDATA"
VOLUME /var/lib/postgresql/data

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 777 /usr/local/bin/docker-entrypoint.sh
RUN ln -s usr/local/bin/docker-entrypoint.sh / 
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 5432
EXPOSE 9090
EXPOSE 9093
EXPOSE 8161
EXPOSE 61616
EXPOSE 2003
EXPOSE 8080
EXPOSE 8443
EXPOSE 32161
EXPOSE 31616
EXPOSE 32003
EXPOSE 32090
EXPOSE 32093
EXPOSE 32432
CMD ["postgres"]