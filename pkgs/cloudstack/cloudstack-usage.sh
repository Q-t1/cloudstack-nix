#!@shell@
# Starts the Apache CloudStack usage server, which turns the management
# server's usage events into usage records, as upstream's systemd unit does:
# with the JVM options, classpath and main class of its
# packaging/systemd/cloudstack-usage.default, mapped to this package's paths.
#
# Environment:
#   CLOUDSTACK_CONF_DIR  directory holding db.properties, log4j-cloud.xml and
#                        the encryption key file `key`, where upstream has
#                        /etc/cloudstack/usage.
#                        Default: /etc/cloudstack/usage
#   JAVA_OPTS            extra JVM options, word-split. They come after
#                        upstream's, so the ones set here win.
#   JAVA_DEBUG           JVM debugging options, as upstream's.
set -eu

conf_dir="${CLOUDSTACK_CONF_DIR:-/etc/cloudstack/usage}"

# The usage server records its process id with its jobs, from -Dpid, which
# upstream's unit sets to the shell's; exec keeps it. The system property
# after upstream's options replaces the path of the sanity check's state
# file, /usr/local/libexec/sanity-check-last-id upstream, which this
# package's build patches out of the code.
# shellcheck disable=SC2086
exec "@jre@/bin/java" \
  -Dpid=$$ \
  @upstreamJavaOpts@ \
  -Dcloudstack.usage.sanity.check.file=/var/lib/cloudstack/usage/sanity-check-last-id \
  ${JAVA_DEBUG:-} \
  ${JAVA_OPTS:-} \
  -cp "@upstreamClasspath@" \
  @upstreamMainClass@ "$@"
