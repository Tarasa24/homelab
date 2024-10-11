{ pkgs, lib, config, inputs, ... }:

{
  packages = [ pkgs.git pkgs.git-crypt pkgs.sshpass pkgs.ansible-lint ];

  languages.terraform.enable = true;
  languages.ansible.enable = true;

  enterShell = ''
  '';
}
