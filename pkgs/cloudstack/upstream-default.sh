# Shell functions for the packaging derivations, to build launchers from
# upstream's packaging/systemd/*.default files: the environment files of its
# systemd units, which set the JVM options, the classpath and the main class.
# Anything they cannot map to this package's paths fails the build, so that a
# change upstream gets reviewed rather than lost.

# readUpstreamDefault FILE CLASS_VARIABLE
# Sets upstreamJavaOpts, upstreamClasspath and upstreamMainClass from FILE's
# JAVA_OPTS, CLASSPATH and CLASS_VARIABLE.
readUpstreamDefault() {
  local file=$1 classVariable=$2 values name
  # The file only assigns variables; read it in a clean shell.
  values=$(env -i "$BASH" -c 'set -eu; . "$1"; printf "%s\n" "$JAVA_OPTS" "$CLASSPATH" "${!2}"' \
    _ "$file" "$classVariable") || {
    echo "error: cannot read JAVA_OPTS, CLASSPATH and $classVariable from $file" >&2
    exit 1
  }
  {
    read -r upstreamJavaOpts
    read -r upstreamClasspath
    read -r upstreamMainClass
  } <<<"$values"
  for name in upstreamJavaOpts upstreamClasspath upstreamMainClass; do
    case ${!name} in
      '')
        echo "error: $file: empty value for $name" >&2
        exit 1
        ;;
      # The values go into a shell script.
      *[\"\'\\\`\$]*)
        echo "error: $file: unexpected character in $name: ${!name}" >&2
        exit 1
        ;;
    esac
  done
}

# mapUpstreamClasspath CLASSPATH ENTRY=REPLACEMENT...
# Prints CLASSPATH with each entry replaced as its rule says (an empty
# replacement drops it). An entry without a rule is an error.
mapUpstreamClasspath() {
  local - classpath=$1 entry rule result=()
  shift
  # The entries are globs for Java, not for this shell.
  set -f
  local IFS=:
  for entry in $classpath; do
    for rule in "$@"; do
      if [ "${rule%%=*}" = "$entry" ]; then
        [ -n "${rule#*=}" ] && result+=("${rule#*=}")
        continue 2
      fi
    done
    echo "error: no mapping for upstream classpath entry $entry" >&2
    exit 1
  done
  echo "${result[*]}"
}

# mapUpstreamOptions OPTIONS FROM=TO...
# Prints OPTIONS with the paths under FROM replaced by TO, the first matching
# rule for each option. An option still naming a path under /etc or /usr is
# an error; a rule mapping a path to itself accepts it.
mapUpstreamOptions() {
  local - options=$1 option rule mapped result=()
  shift
  set -f
  for option in $options; do
    mapped=
    for rule in "$@"; do
      case $option in
        *"${rule%%=*}"*)
          mapped=${option//"${rule%%=*}"/"${rule#*=}"}
          break
          ;;
      esac
    done
    if [ -z "$mapped" ]; then
      case $option in
        /etc/* | /usr/* | *=/etc/* | *=/usr/*)
          echo "error: no mapping for the path in upstream JVM option $option" >&2
          exit 1
          ;;
      esac
      mapped=$option
    fi
    result+=("$mapped")
  done
  echo "${result[*]}"
}
