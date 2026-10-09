#!@shell@
# Starts the Apache CloudStack KVM agent.
#
# Environment:
#   CLOUDSTACK_CONF_DIR  directory holding agent.properties,
#                        environment.properties, log4j-cloud.xml and
#                        uefi.properties. It goes first on the classpath,
#                        which is where the agent looks for them, and must be
#                        writable: the agent updates agent.properties and
#                        keeps its keystore next to it.
#                        Default: /etc/cloudstack/agent, the only directory
#                        the management server's host setup over SSH knows.
#                        The agent also reads its log configuration from
#                        there first, whatever this says.
#   JAVA_OPTS            extra JVM options, word-split. They come after the
#                        defaults below, so -D options set here win.
#   CLOUDSTACK_EXTRA_CLASSPATH
#                        classpath entries appended to the defaults, e.g.
#                        plugin jars (upstream's /usr/share/cloudstack-agent/plugins).
set -eu

conf_dir="${CLOUDSTACK_CONF_DIR:-/etc/cloudstack/agent}"
share="@out@/share"

# libvirt-java loads libvirt through JNA, which needs to be told where it is.
# shellcheck disable=SC2086
exec "@jre@/bin/java" \
  -Djna.library.path="@libvirt@/lib" \
  ${JAVA_OPTS:-} \
  -cp "$conf_dir:$share/cloudstack-agent/lib/*:$share/cloudstack-common/scripts${CLOUDSTACK_EXTRA_CLASSPATH:+:$CLOUDSTACK_EXTRA_CLASSPATH}" \
  com.cloud.agent.AgentShell "$@"
