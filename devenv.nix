{ pkgs, lib, config, inputs, ... }:

{
  env.LC_ALL = "en_US.UTF-8";

  packages = [ pkgs.git pkgs.git-crypt pkgs.sshpass pkgs.ansible-lint ];

  languages.terraform.enable = true;
  languages.ansible.enable = true;

  enterShell = ''
  '';
}
