# kin/homebridge — one LAN-facing bridge; setup and network rules: docs/homebridge.md.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/homebridge";
  manifest.description = "Homebridge on k3s with persistent configuration and HomeKit discovery.";
  manifest.categories = [ "System" ];

  roles.default = {
    description = "Run Homebridge on the k3s server that applies its manifests.";
    perInstance =
      { ... }:
      {
        nixosModule =
          { config, ... }:
          let
            image = "homebridge/homebridge:2026-11-02";
            volumeMounts = [
              {
                name = "data";
                mountPath = "/homebridge";
              }
            ];
          in
          {
            networking.firewall.allowedTCPPorts = [
              8581 # Admin UI; UniFi restricts access to admin machines.
              51826 # Main HomeKit bridge; child bridges need their own ports.
            ];
            networking.firewall.allowedUDPPorts = [ 5353 ];

            systemd.services.homebridge-mdns = {
              description = "Publish homebridge.local without replacing atlas.local";
              wantedBy = [ "multi-user.target" ];
              wants = [ "avahi-daemon.service" ];
              after = [ "avahi-daemon.service" ];
              serviceConfig = {
                # A reverse record for this IP already belongs to atlas.local.
                ExecStart = "${config.services.avahi.package}/bin/avahi-publish-address --no-fail --no-reverse homebridge.local 10.10.3.100";
                DynamicUser = true;
                Restart = "on-failure";
                RestartSec = 5;
              };
            };

            services.k3s.manifests.homebridge.content = [
              {
                apiVersion = "v1";
                kind = "Namespace";
                metadata.name = "homebridge";
              }
              {
                apiVersion = "v1";
                kind = "PersistentVolumeClaim";
                metadata = {
                  name = "homebridge";
                  namespace = "homebridge";
                };
                spec = {
                  accessModes = [ "ReadWriteOnce" ];
                  storageClassName = "longhorn";
                  resources.requests.storage = "5Gi";
                };
              }
              {
                apiVersion = "apps/v1";
                kind = "Deployment";
                metadata = {
                  name = "homebridge";
                  namespace = "homebridge";
                };
                spec = {
                  replicas = 1;
                  # Never run two bridges with the same identity or shared volume.
                  strategy.type = "Recreate";
                  selector.matchLabels.app = "homebridge";
                  template = {
                    metadata.labels.app = "homebridge";
                    spec = {
                      # HomeKit multicast cannot use a ClusterIP or ingress.
                      hostNetwork = true;
                      dnsPolicy = "ClusterFirstWithHostNet";
                      nodeSelector."kubernetes.io/hostname" = config.networking.hostName;
                      automountServiceAccountToken = false;
                      initContainers = [
                        {
                          name = "bootstrap";
                          inherit image volumeMounts;
                          workingDir = "/homebridge";
                          command = [
                            "/opt/homebridge/bin/node"
                            "-e"
                            (builtins.readFile ./bootstrap.cjs)
                          ];
                          env = [
                            {
                              name = "HOMEBRIDGE_BIND";
                              valueFrom.fieldRef.fieldPath = "status.hostIP";
                            }
                          ];
                        }
                      ];
                      containers = [
                        {
                          name = "homebridge";
                          inherit image volumeMounts;
                          env = [
                            # Use ciao instead of a second Avahi daemon on the host.
                            {
                              name = "ENABLE_AVAHI";
                              value = "0";
                            }
                            {
                              name = "TZ";
                              value = config.time.timeZone;
                            }
                          ];
                          ports = [
                            {
                              name = "ui";
                              containerPort = 8581;
                            }
                            {
                              name = "homekit";
                              containerPort = 51826;
                            }
                          ];
                          resources = {
                            requests = {
                              cpu = "100m";
                              memory = "256Mi";
                            };
                            limits.memory = "1Gi";
                          };
                          readinessProbe = {
                            httpGet = {
                              path = "/";
                              port = "ui";
                            };
                            periodSeconds = 10;
                            timeoutSeconds = 5;
                          };
                        }
                      ];
                      volumes = [
                        {
                          name = "data";
                          persistentVolumeClaim.claimName = "homebridge";
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
                  name = "homebridge";
                  namespace = "homebridge";
                };
                spec = {
                  selector.app = "homebridge";
                  ports = [
                    {
                      name = "http";
                      port = 80;
                      targetPort = "ui";
                    }
                  ];
                };
              }
              {
                apiVersion = "networking.k8s.io/v1";
                kind = "Ingress";
                metadata = {
                  name = "homebridge";
                  namespace = "homebridge";
                  annotations."traefik.ingress.kubernetes.io/router.entrypoints" = "web";
                };
                spec = {
                  ingressClassName = "traefik";
                  rules = [
                    {
                      host = "homebridge.local";
                      http.paths = [
                        {
                          path = "/";
                          pathType = "Prefix";
                          backend.service = {
                            name = "homebridge";
                            port.number = 80;
                          };
                        }
                      ];
                    }
                  ];
                };
              }
            ];
          };
      };
  };
}
