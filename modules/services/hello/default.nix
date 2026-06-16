# kin/hello — minimal public demo origin for the Cloudflare Tunnel.
# Serves a static "Hello from the homelab" page from nginx (unprivileged image,
# non-root, no caps, no service-account token). The cloudflared connector points
# at this Service's in-cluster DNS name; nothing here is internet-facing on its
# own. Manifests are applied from the k3s-server (atlas); pods schedule anywhere.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/hello";
  manifest.description = "Static hello-world origin behind the Cloudflare Tunnel.";
  manifest.categories = [ "Network" ];

  roles.default = {
    description = "Deploy the hello demo origin from this server.";
    perInstance =
      { ... }:
      {
        nixosModule =
          { ... }:
          let
            namespace = "hello";
            html = ''
              <!doctype html>
              <html lang="en">
                <head>
                  <meta charset="utf-8" />
                  <meta name="viewport" content="width=device-width, initial-scale=1" />
                  <title>kin</title>
                </head>
                <body>
                  <h1>Hello from the homelab</h1>
                </body>
              </html>
            '';
          in
          {
            services.k3s.manifests.hello.content = [
              {
                apiVersion = "v1";
                kind = "Namespace";
                metadata.name = namespace;
              }
              {
                apiVersion = "v1";
                kind = "ConfigMap";
                metadata = {
                  name = "hello-html";
                  namespace = namespace;
                };
                data."index.html" = html;
              }
              {
                apiVersion = "apps/v1";
                kind = "Deployment";
                metadata = {
                  name = "hello";
                  namespace = namespace;
                };
                spec = {
                  replicas = 1;
                  selector.matchLabels.app = "hello";
                  template = {
                    metadata.labels.app = "hello";
                    spec = {
                      # No API access from this pod — it just serves static HTML.
                      automountServiceAccountToken = false;
                      securityContext = {
                        runAsNonRoot = true;
                        runAsUser = 101; # nginx-unprivileged
                        runAsGroup = 101;
                        seccompProfile.type = "RuntimeDefault";
                      };
                      containers = [
                        {
                          name = "nginx";
                          # Unprivileged image listens on 8080 as uid 101.
                          image = "nginxinc/nginx-unprivileged:1.27-alpine";
                          ports = [ { containerPort = 8080; } ];
                          securityContext = {
                            allowPrivilegeEscalation = false;
                            capabilities.drop = [ "ALL" ];
                          };
                          volumeMounts = [
                            {
                              name = "html";
                              mountPath = "/usr/share/nginx/html";
                              readOnly = true;
                            }
                          ];
                        }
                      ];
                      volumes = [
                        {
                          name = "html";
                          configMap.name = "hello-html";
                        }
                      ];
                    };
                  };
                };
              }
              {
                apiVersion = "v1";
                kind = "Service";
                metadata = {
                  name = "hello";
                  namespace = namespace;
                };
                spec = {
                  selector.app = "hello";
                  ports = [
                    {
                      port = 80;
                      targetPort = 8080;
                    }
                  ];
                };
              }
            ];
          };
      };
  };
}
