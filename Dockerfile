# syntax=docker/dockerfile:experimental
# Dockerfile for drupal-static build

ARG REPOSITORY
ARG TAG
FROM ${REPOSITORY}/drupal:${TAG}
ARG PHPINI__MEMORY_LIMIT=256m

USER nginx

# Allow build to override default envar used in above /etc/php6/conf.d/99-idc.ini:
ENV IDC_MEMORY_LIMIT ${PHPINI__MEMORY_LIMIT}

# Run composer install as application user:
# Normal startup (via /init) must also happen as root
USER root
COPY --chown=nginx:www-data codebase /var/www/drupal/
COPY --chown=0:0 rootfs /
RUN  \
    /bin/rm -f /etc/php7/conf.d/99-idc.ini && \
    for dirname in /var/www/drupal/{vendor,web} ; do \
      if [ -d "$dirname" ] ; then \
        find "$dirname" \! -user nginx -exec chown -v nginx:www-data  {} \; ; \
      fi ; \
    done && \
    chmod 0750 /var/www/drupal/fix_permissions.sh && \
    /var/www/drupal/fix_permissions.sh /var/www/drupal/web nginx 

# Run composer install as unprivileged user:
USER nginx
RUN \
    COMPOSER_MEMORY_LIMIT=-1 COMPOSER_DISCARD_CHANGES=true composer install --no-interaction --no-progress --prefer-dist && \
    composer clearcache

# /init process must be run as root:
USER root
