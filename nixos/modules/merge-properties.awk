# awk -f merge-properties.awk DECLARED BASE
#
# Prints the .properties file BASE with the entries of DECLARED in place of
# BASE's entries with the same keys, in BASE's order, and those that BASE
# lacks at the end. Comments and other lines of BASE are kept. Entries span
# one line: CloudStack's files do not continue lines.

# The key of an entry line, or "" for comments and blank lines.
function key(line) {
  sub(/^[ \t\f]+/, "", line)
  if (line ~ /^[#!]/ || !match(line, /^([^=: \t\f\\]|\\.)+/)) return ""
  return substr(line, 1, RLENGTH)
}

# The last of DECLARED's entries with a key wins, as for Java.
NR == FNR {
  k = key($0)
  if (k != "") {
    if (!(k in declared)) order[++n] = k
    declared[k] = $0
  }
  next
}

{ k = key($0) }

k != "" && (k in declared) {
  if (!(k in written)) print declared[k]
  written[k] = 1
  next
}

{ print }

END {
  for (i = 1; i <= n; i++)
    if (!(order[i] in written)) print declared[order[i]]
}
