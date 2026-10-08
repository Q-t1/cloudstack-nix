#!@shell@
# Starts the Apache CloudStack management server (embedded Jetty).
#
# Environment:
#   CLOUDSTACK_CONF_DIR  directory holding db.properties, server.properties,
#                        environment.properties, log4j-cloud.xml and the
#                        encryption key file `key`. It goes first on the
#                        classpath, which is where CloudStack looks for them.
#                        Default: /etc/cloudstack/management
#   JAVA_OPTS            extra JVM options, word-split. They come after the
#                        defaults below, so -D options set here win.
set -eu

conf_dir="${CLOUDSTACK_CONF_DIR:-/etc/cloudstack/management}"
share="@out@/share"

# shellcheck disable=SC2086
exec "@jre@/bin/java" \
  -Djava.awt.headless=true \
  -Djava.security.properties="$share/cloudstack-management/conf/java.security.ciphers" \
  --add-opens=java.base/java.lang=ALL-UNNAMED \
  --add-exports=java.base/sun.security.x509=ALL-UNNAMED \
  -Dcloudstack.systemvm.templates.path="$share/cloudstack-management/templates/systemvm/" \
  -Dcloudstack.cks.config.path="$share/cloudstack-management/cks" \
  -Dcloudstack.extensions.path=/var/lib/cloudstack/extensions \
  ${JAVA_OPTS:-} \
  -cp "$conf_dir:$share/cloudstack-management/lib/*:$share/cloudstack-common:$share/cloudstack-management/setup:$share/cloudstack-management" \
  org.apache.cloudstack.ServerDaemon "$@"
