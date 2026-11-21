# NVIDIA Grace / DGX Spark ARM64 (`aarch64-linux`) reference workstation & server host.
{
  imports = [ ./reference-workstation.nix ];

  networking.hostName = "spark";
  omarchnix.profile = "spark";
}
