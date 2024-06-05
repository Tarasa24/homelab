{ pkgs ? import <nixpkgs> { config.allowUnfree = true; } }:

pkgs.mkShell {
  # nativeBuildInputs is usually what you want -- tools you need to run
  nativeBuildInputs = with pkgs.buildPackages; [
    terraform
    ansible ansible-lint
    git-crypt sshpass
  ];

  shellHook = ''
    export LC_ALL="C.UTF-8";
    codium .
  '';

  name="Homelab Dev Shell";
}
