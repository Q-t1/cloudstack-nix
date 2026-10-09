#!@shell@
# Starts the Apache CloudStack management server (embedded Jetty) as
# upstream's systemd unit does, with the JVM options, classpath and main class
# of its packaging/systemd/cloudstack-management.default, mapped to this
# package's paths.
#
# Environment:
#   CLOUDSTACK_CONF_DIR  directory holding db.properties, server.properties,
#                        environment.properties, log4j-cloud.xml,
#                        java.security.ciphers and the encryption key file
#                        `key`, where upstream has /etc/cloudstack/management.
#                        Default: /etc/cloudstack/management
#   JAVA_OPTS            extra JVM options, word-split. They come after
#                        upstream's and this package's, so the ones set here
#                        win.
#   JAVA_DEBUG           JVM debugging options, as upstream's.
#   CLOUDSTACK_EXTRA_CLASSPATH
#                        classpath entries appended to upstream's, e.g.
#                        @out@/share/cloudstack-management/simulator/*
#                        for the simulator hypervisor.
set -eu

conf_dir="${CLOUDSTACK_CONF_DIR:-/etc/cloudstack/management}"
share="@out@/share"

# The system properties after upstream's options replace install paths that
# this package's build patches out of the code.
# shellcheck disable=SC2086
exec "@jre@/bin/java" \
  ${JAVA_DEBUG:-} \
  @upstreamJavaOpts@ \
  -Dcloudstack.systemvm.templates.path="$share/cloudstack-management/templates/systemvm/" \
  -Dcloudstack.cks.config.path="$share/cloudstack-management/cks" \
  -Dcloudstack.extensions.path=/var/lib/cloudstack/extensions \
  ${JAVA_OPTS:-} \
  -cp "@upstreamClasspath@${CLOUDSTACK_EXTRA_CLASSPATH:+:$CLOUDSTACK_EXTRA_CLASSPATH}" \
  @upstreamMainClass@ "$@"
