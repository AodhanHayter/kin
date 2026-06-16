# kin/cloudflared — expose in-cluster services to the public internet via a
# Cloudflare Tunnel (outbound-only, no port-forward, home IP never exposed).
# cloudflared runs as a 2-replica Deployment and dials OUT to Cloudflare's edge;
# the public-hostname -> origin map (e.g. lab.aodhanhayter.com ->
# http://<svc>.<ns>.svc.cluster.local:<port>) lives in the Cloudflare Zero Trust
# dashboard (remotely-managed tunnel), so this module is app-agnostic and only
# carries the tunnel token. Single role, applied to the k3s-server (atlas) where
# the token is consumed.
#
# The token is a remotely-managed tunnel token (eyJ...), prompted once:
#   clan vars generate
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/cloudflared";
  manifest.description = "Cloudflare Tunnel connector, deployed into k3s.";
  manifest.categories = [ "Network" ];

  roles.default = {
    description = "Run the cloudflared connector from this server.";
    perInstance =
      { ... }:
      {
        nixosModule =
          { config, ... }:
          let
            # Bump to the current release; check
            # https://hub.docker.com/r/cloudflare/cloudflared/tags
            image = "cloudflare/cloudflared:2025.11.1";
            namespace = "cloudflared";
            secretName = "tunnel-token";

            tokenPath = config.clan.core.vars.generators.cloudflared-tunnel-token.files."token".path;
          in
          {
            # Tunnel token — consumed only here (server), so scoped to the
            # instance. It is a bearer credential (anyone holding it can run a
            # connector for your tunnel), so it never lands in a manifest.
            clan.core.vars.generators.cloudflared-tunnel-token = {
              prompts.token = {
                description = "Cloudflare remotely-managed tunnel token (eyJ...)";
                type = "hidden";
                persist = true;
              };
            };

            services.k3s.manifests.cloudflared.content = [
              {
                apiVersion = "v1";
                kind = "Namespace";
                metadata.name = namespace;
              }
              {
                apiVersion = "apps/v1";
                kind = "Deployment";
                metadata = {
                  name = "cloudflared";
                  namespace = namespace;
                };
                spec = {
                  replicas = 2; # HA, not throughput
                  selector.matchLabels.app = "cloudflared";
                  template = {
                    metadata.labels.app = "cloudflared";
                    spec.containers = [
                      {
                        name = "cloudflared";
                        inherit image;
                        args = [
                          "tunnel"
                          "--no-autoupdate"
                          # http2 transport: QUIC's UDP datagram handler flaps
                          # on these nodes (kernel net.core.rmem_max ~208KiB <<
                          # the 7MiB cloudflared wants), and we only proxy HTTP,
                          # so QUIC buys nothing. http2 is stable + contained.
                          "--protocol"
                          "http2"
                          "--loglevel"
                          "info"
                          "run"
                        ];
                        env = [
                          {
                            name = "TUNNEL_TOKEN";
                            valueFrom.secretKeyRef = {
                              name = secretName;
                              key = "token";
                            };
                          }
                        ];
                      }
                    ];
                  };
                };
              }
            ];

            # The token can't live in the manifest (nix store is world-readable),
            # so it is synced from the sops-decrypted var into a k8s Secret at
            # boot — same shape as the ARC PAT / grafana-admin sync.
            systemd.services.cloudflared-token = {
              description = "Sync the Cloudflare tunnel token into the cloudflared namespace";
              wantedBy = [ "multi-user.target" ];
              after = [ "k3s.service" ];
              wants = [ "k3s.service" ];
              path = [ config.services.k3s.package ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
                until k3s kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done
                k3s kubectl create namespace ${namespace} --dry-run=client -o yaml \
                  | k3s kubectl apply -f -
                k3s kubectl -n ${namespace} create secret generic ${secretName} \
                  --from-file=token=${tokenPath} \
                  --dry-run=client -o yaml | k3s kubectl apply -f -
              '';
            };
          };
      };
  };
}
