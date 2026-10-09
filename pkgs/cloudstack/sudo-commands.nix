# The commands that the management server runs through sudo (secondary
# storage mounts, system VM template seeding): upstream's
# server/conf/cloudstack-sudoers.in, its Cmnd_Alias CLOUDSTACK, by the paths it
# names there, with the programs that stand for them here.
# checks.upstream-files fails when upstream's list changes.
{
  coreutils,
  findutils,
  util-linux,
  qemu-utils,
  jre,
}:

{
  commands = {
    "/bin/mkdir" = "${coreutils}/bin/mkdir";
    "/bin/mount" = "${util-linux}/bin/mount";
    "/bin/umount" = "${util-linux}/bin/umount";
    "/bin/cp" = "${coreutils}/bin/cp";
    "/bin/chmod" = "${coreutils}/bin/chmod";
    "/usr/bin/keytool" = "${jre}/bin/keytool";
    "/bin/keytool" = "${jre}/bin/keytool";
    "/bin/touch" = "${coreutils}/bin/touch";
    "/bin/find" = "${findutils}/bin/find";
    "/bin/df" = "${coreutils}/bin/df";
    "/bin/ls" = "${coreutils}/bin/ls";
    "/bin/qemu-img" = "${qemu-utils}/bin/qemu-img";
    "/usr/bin/qemu-img" = "${qemu-utils}/bin/qemu-img";
  };

  # sudo looks the commands up in the service's PATH and matches the result
  # against the rules, so these packages go first in that PATH.
  packages = [
    coreutils
    findutils
    util-linux
    qemu-utils
    jre
  ];
}
