#!@shell@
# Starts the Apache CloudStack usage server, which turns the management
# server's usage events into usage records.
#
# Environment:
#   CLOUDSTACK_CONF_DIR  directory holding db.properties, log4j-cloud.xml and
#                        the encryption key file `key`. It goes first on the
#                        classpath, which is where CloudStack looks for them.
#                        Default: /etc/cloudstack/usage
#   JAVA_OPTS            extra JVM options, word-split.
set -eu

conf_dir="${CLOUDSTACK_CONF_DIR:-/etc/cloudstack/usage}"
share="@out@/share"

# The usage server records its process id with its jobs, from -Dpid. exec
# keeps the shell's.
# shellcheck disable=SC2086
exec "@jre@/bin/java" \
  -Dpid=$$ \
  --add-opens=java.base/java.lang=ALL-UNNAMED \
  ${JAVA_OPTS:-} \
  -cp "$conf_dir:$share/cloudstack-usage/lib/*" \
  com.cloud.usage.UsageServer "$@"
