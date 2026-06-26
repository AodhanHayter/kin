# kin/wifi — declarative NetworkManager wifi for nodes with no ethernet (the mbp
# MacBookPro joins the LAN over broadcom wifi). The SSID + PSK are prompted once
# into an encrypted clan var emitted as an env file; NetworkManager's
# ensureProfiles substitutes them into a keyfile connection at activation, so a
# rebuilt node reconnects with no manual nmtui/iwctl. Assigned per-machine in
# clan.nix (roles.default.machines.mbp).
#
# The broadcom `wl` driver itself is hardware → modules/hardware/macbook-pro-11-5.
# NetworkManager itself is enabled cluster-wide by kin/base.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/wifi";
  manifest.description = "Declarative NetworkManager wifi (SSID + PSK from a prompted clan var).";
  manifest.categories = [ "Network" ];

  roles.default = {
    description = "Bring up a declarative wifi connection on this machine.";
    perInstance =
      { ... }:
      {
        nixosModule =
          { config, ... }:
          {
            # SSID + PSK prompted once at `clan vars generate`, stored encrypted,
            # emitted as an env file NetworkManager reads when activating the
            # profile below. persist=false → only the derived env file is kept.
            clan.core.vars.generators.wifi = {
              prompts.ssid = {
                description = "WiFi SSID";
                type = "line";
                persist = false;
              };
              prompts.psk = {
                description = "WiFi password / PSK";
                type = "hidden";
                persist = false;
              };
              files."wifi.env".secret = true;
              script = ''
                printf 'WIFI_SSID=%s\nWIFI_PSK=%s\n' \
                  "$(cat "$prompts"/ssid)" "$(cat "$prompts"/psk)" > "$out"/wifi.env
              '';
            };

            networking.networkmanager.ensureProfiles = {
              environmentFiles = [
                config.clan.core.vars.generators.wifi.files."wifi.env".path
              ];
              profiles.kin-wifi = {
                connection = {
                  id = "kin-wifi";
                  type = "wifi";
                  autoconnect = true;
                };
                wifi = {
                  ssid = "$WIFI_SSID";
                  mode = "infrastructure";
                };
                wifi-security = {
                  key-mgmt = "wpa-psk";
                  psk = "$WIFI_PSK";
                };
                ipv4.method = "auto";
                ipv6.method = "auto";
              };
            };
          };
      };
  };
}
