.DEFAULT_GOAL := default
# Establish "GIT_TAG" as the the current commit reference for the repo;
# this will be used later to establish container image tags:
GIT_TAG := $(shell git describe --tags --always)

# Bootstrap a new instance without Fedora.  Assumes there is a Drupal site in ./codebase.
# Will do a clean Drupal install and initialization
#
# (TODO: generally make ISLE more robust to the choice to omit fedora.
# otherwise we could of simply done 'hydrate' instead of update-settings-php, update-config... etc)
.PHONY: bootstrap
.SILENT: bootstrap
bootstrap: snapshot-empty default destroy-state up install \
	update-settings-php update-config-from-environment solr-cores run-islandora-migrations \
	git checkout -- .env
	@echo "  └─ Bootstrap complete."

# Rebuilds the Drupal cache
.PHONY: cache-rebuild
.SILENT: cache-rebuild
cache-rebuild: 
	echo "rebuilding Drupal cache..."
	docker-compose exec -T drupal drush cr -y

.PHONY: destroy-state
.SILENT: destroy-state
destroy-state:
	# In case the file is empty, rebuild it
	$(MAKE) -B docker-compose.yml
	echo "Destroying docker-compose volume state"
	docker-compose down -v
	-rm -rf docker-compose.yml
	-rm -rf .docker-compose.yml

.PHONY: composer-install
.SILENT: composer-install
composer-install:
	echo "Installing via composer"
	docker-compose exec -T drupal bash -lc "COMPOSER_MEMORY_LIMIT=-1 COMPOSER_DISCARD_CHANGES=true composer install --no-interaction --no-progress"


.PHONY: snapshot-image
.SILENT: snapshot-image
snapshot-image:
	${MAKE} db_dump
	docker-compose stop
	docker run --rm --volumes-from snapshot \
		-v ${PWD}/snapshot:/dump \
		alpine:latest \
		/bin/tar cvf /dump/data.tar /data
	TAG=${GIT_TAG}.`date +%s` && \
		docker build -t ${REPOSITORY}/snapshot:$$TAG ./snapshot && \
		cat .env | sed s/SNAPSHOT_TAG=.*/SNAPSHOT_TAG=$$TAG/ > /tmp/.env && \
	  cp /tmp/.env .env && \
	  rm /tmp/.env
	-rm -f .docker-compose.yml
	$(MAKE) -B docker-compose.yml
	docker-compose up -d

.PHONY: reset
.SILENT: reset
reset: warning-destroy-state destroy-state
	@echo "Resetting permissions. This will take a while..."
	$(MAKE) set-codebase-owner
	@echo "Removing vendored modules"
	-rm -rf codebase/modules
	-rm -rf codebase/vendor
	-rm -rf codebase/web/core
	-rm -rf codebase/web/modules/contrib
	-rm -rf codebase/web/themes/contrib
	@echo "Re-generating docker-compose.yml"
	@echo "Starting ..."
	@echo "Invoke 'docker-compose logs -f drupal' in another terminal to monitor startup progress"
	$(MAKE) up

.PHONY: warning-destroy-state
.SILENT: warning-destroy-state
warning-destroy-state:
	@echo "WARNING: Resetting state to snapshot ${SNAPSHOT_TAG}.  This will:"
	@echo "1. Remove all modules and dependencies under:"
	@echo "  codebase/vendor"
	@echo "  codebase/web/core"
	@echo "  codebase/modules/contrib"
	@echo "  codebase/themes/contrib"
	@echo "2. Re-generate docker-compose.yml"
	@echo "3. Pull the latest images"
	@echo "4. Re-install modules from composer.json"
	@echo "WARNING: continue? [Y/n]"
	@echo -n "Are you sure? [y/N] " && read ans ; [ $${ans:-N} = y ] || [ $${ans:-N} = Y ] || exit 1

.PHONY: snapshot-empty
.SILENT: snapshot-empty
snapshot-empty:
	sed s/SNAPSHOT_TAG=.*/SNAPSHOT_TAG=empty/ .env > /tmp/.env && \
		cp /tmp/.env .env && \
		rm /tmp/.env
	$(MAKE) -B docker-compose.yml
	docker build -f snapshot/empty.Dockerfile -t ${REPOSITORY}/snapshot:empty ./snapshot

.PHONY: snapshot-push
.SILENT: snapshot-push
snapshot-push:
	docker push ${REPOSITORY}/snapshot:${SNAPSHOT_TAG}

.PHONY: up
.SILENT: up
up:  download-default-certs static-drupal-image docker-compose.yml start

.PHONY: down
.SILENT: down
## Brings down the containers. Same as docker-compose down --remove-orphans
down:
	-docker-compose down -v --remove-orphans

.PHONY: dev-up
.SILENT: dev-up
dev-up:  download-default-certs
	-docker-compose stop drupal
	-docker-compose rm -f drupal
	sed s/ENVIRONMENT=.*/ENVIRONMENT=drupal-dev/ .env > /tmp/.env && \
		cp /tmp/.env .env && \
		rm /tmp/.env
	$(MAKE) -B docker-compose.yml start
	docker-compose exec drupal with-contenv bash -lc "echo \"alias drupal='vendor/drupal/console/bin/drupal'\" >> ~/.bashrc"
	docker-compose exec drupal with-contenv bash -lc "echo \"alias drupal-check='vendor/mglaman/drupal-check/drupal-check'\" >> ~/.bashrc"
	$(MAKE) set-codebase-owner
	docker-compose exec drupal with-contenv bash -lc "chmod 766 /var/www/drupal/xdebug.log"
	# Add twig debugging
	docker cp scripts/services.yml $$(docker ps --format "{{.Names}}" | grep drupal):/var/www/drupal/web/sites/default/services.yml
	sudo chown --reference=codebase/web/sites/default/default.settings.php codebase/web/sites/default/services.yml

.PHONY: dev-down
.SILENT: dev-down
dev-down:  download-default-certs
	sed s/ENVIRONMENT=.*/ENVIRONMENT=local/ .env > /tmp/.env && \
		cp /tmp/.env .env && \
		rm /tmp/.env
	$(MAKE) -B docker-compose.yml
	sudo rm -f codebase/web/sites/default/services.yml
	docker-compose stop drupal
	docker-compose rm -f drupal

.PHONY: start
.SILENT: start
start:
	$(MAKE) -B docker-compose.yml
	docker-compose up -d mariadb snapshot;
	# Try connecting to mariadb, and get a valid (a number, greater than zero) count of the number of databases.
	# Then, once we're "confident" that mariadb is up and validly query able, see if the Drupal db is in place.
	# This is a tricky process, as the mariadb client can succeed once, then fail on a subsequent invocation.
	# Once we've finally determined if mariadb is running, and have found a valid answer for whether the Drupal DB is present,
	# then we can proceed.  If the Drupal DB is not present, then load it from snapshot before starting the stack.
	# Otherwise, if the Drupal db is already present, just start.
	for i in $$(seq 5) ; do \
		echo "waiting for mysql to start..."; \
		sleep 5; \
		BASIC_DBS_PRESENT=$$(docker-compose exec -T mariadb mysql mysql -N -e "SELECT count(*) from information_schema.SCHEMATA;"); \
		if [  "$$?" -gt "0" ]; then continue; fi; \
		if [ ! -n "$$BASIC_DBS_PRESENT" ]; then continue; fi; \
		if [ ! "$$BASIC_DBS_PRESENT" -gt "0" ]; then continue; fi; \
		DRUPAL_STATE_EXISTS=$$(docker-compose exec -T mariadb mysql mysql -N -e "SELECT count(*) from information_schema.SCHEMATA WHERE schema_name = 'drupal_default';"); \
		if [ "$$?" -eq "0" -a -n "$${DRUPAL_STATE_EXISTS}" ]; then break; fi; \
	done; \
	if [ "$${DRUPAL_STATE_EXISTS}" != "1" ] ; then \
		echo "No Drupal state found.  Loading from snapshot, and importing config from config/sync"; \
		${MAKE} db_restore; \
		${MAKE} _docker-up-and-wait; \
	else \
		echo "Pre-existing Drupal state found, not loading db from snapshot"; \
		${MAKE} _docker-up-and-wait; \
	fi;
	$(MAKE) solr-cores
	$(MAKE) config-import
	docker ps -a 
	for i in $$( docker ps -a | grep drupal | awk '{print $$1}' ) ; do echo $$i ; docker inspect "$$i" | grep Image ; done
	echo "Force solr ISLANDORA config"
	docker-compose exec -T drupal bash -c '/bin/rm -f /opt/solr/server/solr/ISLANDORA/conf/solrconfig_extra.xml ; /bin/cp -f /var/www/drupal/assets/solr/solrconfig_extra.xml /opt/solr/server/solr/ISLANDORA/conf/solrconfig_extra.xml'
	echo "Restarting solr"
	docker-compose restart solr

.PHONY: _docker-up-and-wait
.SILENT: _docker-up-and-wait
_docker-up-and-wait:
	docker-compose up -d
	containerId="" ; \
	while [ -z "$$containerId" ] ; do \
		echo "(still) waiting for Drupal container to appear" ; \
		sleep 2; \
		containerId=$$( docker-compose ps -q drupal ) ; \
	done && echo "containerId='$$containerId'"
	# composer config can move forward since container is available:
	if [ "${GH_TOKEN}" ]; then \
		echo "Installing github token"; \
		docker-compose exec -T drupal bash -lc "composer config -g github-oauth.github.com ${GH_TOKEN}" ; \
	else \
		echo "No github token provided" ; \
	fi
	# new block:
	containerId=$$( docker-compose ps -q drupal ) ; \
	echo "Drupal container ID: '$$containerId'" ; \
	containerName=$$(docker inspect -f '{{.Name}}' $$(docker-compose ps -q drupal) | cut -c2-) ; \
	echo "Looking into run-state of found-container '$$containerName'" ; \
	if [ -n "$$containerName" ] ; then \
		healthState="" ; \
		lastLogs="" ; \
		while [ "healthy" != "$$healthState" ] ; do \
			if [ "running" != "$$( docker inspect -f '{{ .State.Status }}' $$containerName )" ] ; then \
				echo "Drupal container has exited. This is abnormal but possibly caused by drupal module sync issue" ; \
				printf "final drupal container logs:\n  ...\n" ; \
				docker-compose logs drupal | tail -30 | sed 's/^/  /' ; \
				exit 1 ; \
			fi ; \
			sleep 10 ; \
			healthState=$$(docker inspect -f {{.State.Health.Status}} "$$containerName") ; \
			if [ "healthy" != "$$healthState" ] ; then \
				echo "Waiting for Drupal to start and accept connections. (state: '$$healthState')" ; \
				logs=$$(docker-compose logs drupal | tail -3 | sed 's/^/  /') ; \
				if [ "$$logs" != "$$lastLogs" ] ; then \
					printf "last drupal container logs:\n  ...\n$$logs\n" ; \
					lastLogs="$$logs" ; \
				fi \
			fi \
		done && \
		echo Drupal is ready. ; \
	fi

# Static drupal image, with codebase baked in.  This image
# is tagged based on the current git hash/tag.  If the image is not present
# locally, nor pullable, then this is built locally.  Ultimately, this image is
# intended be published to cloud instances of the stack
.PHONY: static-drupal-image
.SILENT: static-drupal-image
static-drupal-image:
	IMAGE=${REPOSITORY}/drupal-static:${GIT_TAG} ; \
	EXISTING=`docker images -q $$IMAGE` ; \
	if test -z "$$EXISTING" ; then \
		echo "Building Drupal image with base:  $${REPOSITORY}/drupal:$${TAG} " ; \
		docker build --build-arg REPOSITORY=$${REPOSITORY} --build-arg TAG=$${TAG} -t $${IMAGE} . && \
		docker tag $${IMAGE}  ${REPOSITORY}/drupal-static:static ; \
	else \
		echo "Using existing Drupal image $${EXISTING}" ; \
		docker tag $${EXISTING}  ${REPOSITORY}/drupal-static:static ; \
	fi

# Export a tar of the static drupal image
.PHONY: static-drupal-image-export
.SILENT: static-drupal-image-export
static-drupal-image-export: static-drupal-image
	IMAGE=${REPOSITORY}/drupal-static:${GIT_TAG} ; \
	echo saving docker image $${IMAGE} ; \
	mkdir -p images ; \
	docker save $${IMAGE} > images/static-drupal.tar


# Build a docker-compose file that will run the whole stack, except with
# the static drupal image rather than the dev drupal image + codebase bind mount.
.PHONY: static-docker-compose.yml
.SILENT: static-docker-compose.yml
static-docker-compose.yml: static-drupal-image
	ENV_FILE=.env
	if [ "$(env)" != "" ] ; then echo inherited environment ; ENV_FILE=$(env); fi; \
	echo '' > .env_static && \
		grep -v ^DRUPAL_STATIC_TAG= $${ENV_FILE} | while read line; do \
		if echo $$line | grep -q "ENVIRONMENT" ; then \
			echo "ENVIRONMENT=static" >> .env_static ; \
		else \
			echo $$line >> .env_static ; \
		fi \
		done && \
			echo setting DRUPAL_STATIC_TAG && \
		echo DRUPAL_STATIC_TAG=static >> .env_static
	mv ${ENV_FILE} .env.bak
	mv .env_static ${ENV_FILE}
	echo Building static drupal configuration
	#grep DRUPAL_STATIC_TAG= ${ENV_FILE}
	grep ENVIRONMENT= ${ENV_FILE}
	$(MAKE) -B docker-compose.yml args="--env-file ${ENV_FILE}" || ( echo reverting ${ENV_FILE} ; mv -v .env.bak ${ENV_FILE} )

.SILENT: revert-env
.PHONY:  revert-env

revert-env:
	ENV_FILE=.env
	if [ -f .env.bak ] ; then \
	  echo reverting ${ENV_FILE} ; \
	  mv -v .env.bak ${ENV_FILE} ; \
	fi

.SILENT: test
.PHONY: test
test:
	# Check if jq is installed.  If not, install it.
	if ! [ -x "$(shell command -v jq)" ]; then \
		echo 'Error: jq is not installed.' >&2 ; \
		echo '       Please install jq and try again.' >&2 ; \
		echo '       You can do this by running:  sudo apt-get install jq' >&2 ; \
	fi; \
	./run-tests.sh $(test)

.PHONY: db_dump
.SILENT: db_dump
db_dump:
	docker-compose exec -T mariadb bash -c "mysqldump drupal_default > /mariadb-dump/drupal_default.sql"

.PHONY: db_restore
.SILENT: db_restore
db_restore:
	if [ -z "${DRUPAL_DEFAULT_DB_USER}" ] ; then \
		DRUPAL_DEFAULT_DB_USER=drupal_default; \
	fi; \
	echo "Creating mysql user $${DRUPAL_DEFAULT_DB_USER}"
	docker-compose exec -T mariadb mysql mysql -e "CREATE USER IF NOT EXISTS '$${DRUPAL_DEFAULT_DB_USER}'@'%' IDENTIFIED BY '${DRUPAL_DEFAULT_DB_PASSWORD}'; FLUSH PRIVILEGES"; \
	docker-compose exec -T mariadb bash -c 'mysql mysql -e "DROP DATABASE IF EXISTS drupal_default"'; \
	docker-compose exec -T mariadb bash -c 'mysql mysql -e "CREATE DATABASE drupal_default DEFAULT CHARACTER SET utf8"'; \
	echo "Loading mysql dump"; \
	docker-compose exec -T mariadb bash -c 'mysql drupal_default < /mariadb-dump/drupal_default.sql'; \
	docker-compose exec -T mariadb mysql mysql -e "GRANT ALL PRIVILEGES ON drupal_default.* to '$${DRUPAL_DEFAULT_DB_USER}'@'%';";

.phony: minio-bucket
.silent: minio-bucket
minio-bucket:
	docker run --rm --env-file .env -v $$(pwd)/minio-init.sh:/minio-init.sh --network idc_default --entrypoint=/minio-init.sh minio/mc

NODE=$(shell which node)
NPM=$(shell which npm)
YARN=$(shell which yarn)

# Compile the theme
.PHONY: theme-compile
.SILENT: theme-compile
theme-compile:
	sudo -u $(shell echo $$USER) test -w codebase/web/themes/contrib/idc-ui-theme || { echo $(shell sudo chown -R $$USER: codebase/) ; exit 1; }
	docker-compose exec drupal with-contenv bash -lc 'COMPOSER_MEMORY_LIMIT=-1 composer update jhu-idc/idc-ui-theme'
	$(MAKE) set-codebase-owner
	sudo find ./codebase/web/themes/contrib/idc-ui-theme/ -name 'node_modules' -type d -prune -exec rm -rf '{}' +
	echo $(shell docker rmi $(shell docker images | grep 'idc_theme_build'))
	cd codebase/web/themes/contrib/idc-ui-theme/ && docker build -t idc_theme_build .
	echo "Building theme"
	docker run --rm -v $(shell pwd)/codebase/web/themes/contrib/idc-ui-theme/:/usr/src/project idc_theme_build bash -c "cd js && bash autobuild.sh"
	sudo find ./codebase/web/themes/contrib/idc-ui-theme/js -exec chown $(shell id -u):101 {} \;
	docker-compose exec -T drupal bash -lc "drush cc theme-registry"