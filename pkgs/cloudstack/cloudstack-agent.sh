#!@shell@
# Starts the Apache CloudStack KVM agent as upstream's systemd unit does, with
# the JVM options, classpath and main class of its
# packaging/systemd/cloudstack-agent.default, mapped to this package's paths.
# Upstream's options keep /usr/share/cloudstack-agent/tmp as the temporary
# directory, which services.cloudstack.agent links to its state directory.
#
# Environment:
#   CLOUDSTACK_CONF_DIR  directory holding agent.properties,
#                        environment.properties, log4j-cloud.xml and
#                        uefi.properties, where upstream has
#                        /etc/cloudstack/agent. It must be writable: the agent
#                        updates agent.properties and keeps its keystore next
#                        to it.
#                        Default: /etc/cloudstack/agent, the only directory
#                        the management server's host setup over SSH knows.
#                        The agent also reads its log configuration from
#                        there first, whatever this says.
#   JAVA_OPTS            extra JVM options, word-split. They come after
#                        upstream's and this package's, so the ones set here
#                        win.
#   JAVA_DEBUG           JVM debugging options, as upstream's.
#   CLOUDSTACK_EXTRA_CLASSPATH
#                        classpath entries appended to upstream's, e.g.
#                        plugin jars (upstream's /usr/share/cloudstack-agent/plugins).
set -eu

conf_dir="${CLOUDSTACK_CONF_DIR:-/etc/cloudstack/agent}"

# libvirt-java loads libvirt through JNA, which needs to be told where it is.
# shellcheck disable=SC2086
exec "@jre@/bin/java" \
  @upstreamJavaOpts@ \
  -Djna.library.path="@libvirt@/lib" \
  ${JAVA_DEBUG:-} \
  ${JAVA_OPTS:-} \
  -cp "@upstreamClasspath@${CLOUDSTACK_EXTRA_CLASSPATH:+:$CLOUDSTACK_EXTRA_CLASSPATH}" \
  @upstreamMainClass@ "$@"
