# The machine of `nix run .#demo` (see vm.nix): a management server with the
# simulator hypervisor and the usage server, where cloudstack-demo.service
# deploys a zone on simulated hosts, then a network and a VM, so that the web
# UI opens on a working cloud. Needs the cloudstack-management module.
# tests/demo.nix checks it.
{ lib, pkgs, ... }:

let
  deploy = pkgs.writeShellApplication {
    name = "cloudstack-demo-deploy";
    runtimeInputs = [
      pkgs.cloudmonkey
      pkgs.curl
      pkgs.jq
    ];
    text = builtins.readFile ./deploy.sh;
  };
in
{
  services.cloudstack.management = {
    enable = true;
    simulator.enable = true;
    usage.enable = true;
    openFirewall = true;
    ui.settings.appTitle = "CloudStack on NixOS";
  };

  systemd.services.cloudstack-demo = {
    description = "Apache CloudStack demo zone on the simulator";
    # Like the simulator templates, which it needs, and not before
    # multi-user.target: the first start takes minutes.
    wantedBy = [ "cloudstack-management.service" ];
    requires = [ "cloudstack-management-simulator.service" ];
    after = [ "cloudstack-management-simulator.service" ];
    # CloudMonkey keeps its configuration and API cache there.
    environment.HOME = "%t/cloudstack-demo";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe deploy;
      TimeoutStartSec = "1h";
      # It only talks to the API.
      DynamicUser = true;
      RuntimeDirectory = "cloudstack-demo";
    };
  };
}
