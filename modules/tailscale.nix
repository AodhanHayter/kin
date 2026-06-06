# Tailscale. Service only; `tailscale up` / auth is done out-of-band.
{
  services.tailscale = {
    enable = true;
    openFirewall = true;
  };
}
