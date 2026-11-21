# AMD / Intel (`x86_64-linux`) reference UEFI workstation host.
{
  imports = [ ./reference-workstation.nix ];

  networking.hostName = "workstation";
  omarchnix.profile = "workstation";
}
