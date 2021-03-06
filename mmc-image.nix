#! /usr/bin/env nix-shell
#! nix-shell --pure --packages nixos-generators --run "nixos-generate -I nixpkgs=nix/nixpkgs -f sd-aarch64-installer --system aarch64-linux -c ./mmc-image.nix"

# This file contains a Nix expression that generates an aarch64-linux bootable DOS/MBR
# image when executed. The only dependency is nix-shell(1). The supported target platform
# is the Raspberry Pi 3 Model B. But other revisions and models may boot and even operate
# as expected.
#
# Upon boot the system will establish a reverse SSH proxy to your configured bastion as
# specifed in `config.nix` and start the required services needed for proper operation.
# For convenience, the Nix expression in `nix/ssh-bastion.nix` may be included in the system
# configuration that yields the host pointed to by `config.nix` to automatically setup all
# system-external services that are expected (Arrowhead, etc.)
# (TODO: rewrite the above paragarph)

# TODO: remove cruft we do not need: nixos-install, ZFS, etc.

{ pkgs, lib, config, ... }:

{
  imports = [
    <nixpkgs/nixos/modules/installer/cd-dvd/sd-image-aarch64.nix>
    ./nix/brickpi3.nix
  ];

  sdImage.compressImage = true; # ./build.sh expects a zstd-compress image

  # Latest release of major 5 doesn't always play ball with the hardware.
  # Relase 4.19 is stable and "battle-tested".
  # See <https://github.com/NixOS/nixpkgs/issues/82455>.
  boot.kernelPackages = pkgs.linuxPackages_4_19;

  networking.hostName = "ed7039e";

  # Automatically connect to eduroam via wlan0 for remote access.
  networking.wireless = {
    enable = true;
    interfaces = [ "wlan0" ];
    networks = (import ./local-secrets.nix).networks;
  };
  systemd.services.wpa_supplicant.wantedBy = lib.mkForce [ "default.target" ];

  # Ensure a correct system clock.
  services.timesyncd.enable = true;
  time.timeZone = "Europe/Stockholm";

  # Enables us to inspect core dumps in a centralized manner (incl. timestamps)
  systemd.coredump.enable = true;

  # Automatically log in as root, require no passphrase.
  users.users.root.initialHashedPassword = "";
  services.mingetty.autologinUser = lib.mkForce "root";

  # Automatically start SSH server after boot, and establish a reverse proxy
  # with a known bastion. This allows us to access the system from any system
  # with Internet access (and allows this system to live behind NAT:ed networks).
  services.openssh = {
    enable = true;
    permitRootLogin = "yes";
  };
  systemd.services.sshd.wantedBy = lib.mkForce [ "multi-user.target" ];
  environment.etc."id_rsa" = {
    source = ./id_rsa;
    user = "nixos";
    mode = "0600";
  };
  users.extraUsers.root.openssh.authorizedKeys.keys = lib.attrValues (import ./nix/ssh-keys.nix);
  systemd.services.ssh-port-forward = {
    description = "forwarding reverse SSH connection to a known bastion";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "nss-lookup.target" ];
    serviceConfig = let bastion = (import ./nix/config.nix).bastion; in {
      ExecStart = ''
        ${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=no \
          -TNR ${bastion.socketPath}:localhost:22 ${bastion.user}@${bastion.host} \
          -i /etc/id_rsa
      '';

      StandardError = "journal";
      Type = "simple";

      # Upon exit, try to establish a new connection every 5s.
      Restart = "always";
      RestartSec = "5s";
      StartLimitIntervalSec = "0";
    };
  };

  # Image minification
  # documentation.enable = lib.mkForce false;
  # documentation.nixos.enable = lib.mkForce false;
  environment.noXlibs = lib.mkForce true;
  services.xserver.enable = false;
  services.xserver.desktopManager.xterm.enable = lib.mkForce false;
  services.udisks2.enable = lib.mkForce false;
  security.polkit.enable = lib.mkForce false;
  boot.supportedFilesystems = lib.mkForce [ "vfat" ];
  i18n.supportedLocales = lib.mkForce [ (config.i18n.defaultLocale + "/UTF-8") ];

  # Intall all nodes we have written (from under ./src/) and install
  # all Python dependencies.
  environment.systemPackages = with pkgs; let
    derivations = pkgs.callPackage ./nix/derivations.nix { };
  in [
    screen # for decawave debugging
    git # for convenience (see systemd.clone-robot-repo below)

    # Required libs for Python nodes
    (python3.buildEnv.override {
      extraLibs = (with python3Packages; [
        numpy                   # for motor controller
      ])
      ++ (lib.attrValues derivations.pythonLibs)
      ++ (builtins.attrValues (import ./nix/adafruit-blinka/requirements.nix { inherit pkgs; }).packages);
    })

  ] ++ (with derivations.systemNodes; [
    binaries
    scripts
  ]);

  # Describe the environment properly for the FT232H which we use for
  # line-follwing.
  environment.variables = {
    BLINKA_FT232H = "1";
    LD_LIBRARY_PATH = "${pkgs.libusb}/lib/";
  };

  # Clone this repo to the file system for convenience. While this
  # could be done using some
  #
  #    environment.etc."repo" = fetchgit { ... }
  #
  # that would symlink to the Nix store, and would be read-only.
  systemd.services.clone-robot-repo = {
    description = "Clone the robot's git repository";
    serviceConfig.Type = "oneshot";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    # Try to clone until we succeed (in case Internet connection is spotty).
    script = ''
      mkdir -p /root/repo && cd /root/repo
      while [ ! $(${pkgs.git}/bin/git rev-parse --is-inside-work-tree) ]; do
        ${pkgs.git}/bin/git clone https://github.com/tmplt/ed7039e.git . || true
      done
    '';
  };

  # Required for the LCM UDP multicast transport implementation
  networking.firewall.allowedUDPPorts = [ 7667 ];
}
