# kin/ipa-rfp-model — interactive Fulcrum coal-plant financial model (marimo
# notebook) behind the Cloudflare Tunnel + Access.
#
# The model is two small Python files (app.py + fulcrum.py) that live in the
# PRIVATE ipa-coal-analysis repo and contain deal-sensitive numbers, so they
# are NOT in this public repo. They are applied out-of-band as the
# `ipa-rfp-model` ConfigMap by ipa-coal-analysis/scripts/deploy-model.sh (same
# reasoning as the cloudflared tunnel token: sensitive content never lands in
# a manifest here). The pod Pends until that ConfigMap exists.
#
# The pod is stock python:3.12-slim; an init step pip-installs
# marimo/pandas/plotly into an emptyDir and `marimo run` serves the read-only
# app (each browser session gets its own kernel, so concurrent viewers don't
# stomp each other's sliders).
#
# Exposure (manual, Cloudflare Zero Trust dashboard — same as hello):
#   1. Tunnel public hostname:  ipa-rfp-model.<domain> ->
#        http://ipa-rfp-model.ipa-rfp-model.svc.cluster.local:80
#   2. Access application on ipa-rfp-model.<domain> with an email allow-list.
#      Do NOT skip step 2: marimo run has no auth of its own.
#
# To update the model: rerun deploy-model.sh from ipa-coal-analysis (it
# re-applies the ConfigMap and restarts the Deployment).
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/ipa-rfp-model";
  manifest.description = "Fulcrum financial model (marimo) behind the Cloudflare Tunnel.";
  manifest.categories = [ "Science" ];

  roles.default = {
    description = "Deploy the Fulcrum model origin from this server.";
    perInstance =
      { ... }:
      {
        nixosModule =
          { ... }:
          let
            namespace = "ipa-rfp-model";
            # ponytail: pip install at pod start (~1-2 min cold start, needs
            # egress). Bake an image if restart latency ever matters.
            pipDeps = "marimo==0.24.0 pandas plotly";
          in
          {
            services.k3s.manifests.ipa-rfp-model.content = [
              {
                apiVersion = "v1";
                kind = "Namespace";
                metadata.name = namespace;
              }
              {
                apiVersion = "apps/v1";
                kind = "Deployment";
                metadata = {
                  name = "ipa-rfp-model";
                  namespace = namespace;
                };
                spec = {
                  replicas = 1;
                  selector.matchLabels.app = "ipa-rfp-model";
                  template = {
                    metadata.labels.app = "ipa-rfp-model";
                    spec = {
                      automountServiceAccountToken = false;
                      securityContext = {
                        runAsNonRoot = true;
                        runAsUser = 1000;
                        runAsGroup = 1000;
                        seccompProfile.type = "RuntimeDefault";
                      };
                      containers = [
                        {
                          name = "marimo";
                          image = "python:3.12-slim";
                          command = [
                            "sh"
                            "-c"
                            ''
                              pip install --no-cache-dir --target=/deps ${pipDeps} && \
                              exec python -m marimo run /model/app.py --host 0.0.0.0 -p 2718 --headless
                            ''
                          ];
                          workingDir = "/model";
                          env = [
                            # pip + marimo need a writable HOME; PYTHONPATH picks
                            # up both the emptyDir install and the model files.
                            {
                              name = "HOME";
                              value = "/tmp";
                            }
                            {
                              name = "PYTHONPATH";
                              value = "/deps:/model";
                            }
                          ];
                          ports = [ { containerPort = 2718; } ];
                          securityContext = {
                            allowPrivilegeEscalation = false;
                            capabilities.drop = [ "ALL" ];
                          };
                          volumeMounts = [
                            {
                              name = "model";
                              mountPath = "/model";
                              readOnly = true;
                            }
                            {
                              name = "deps";
                              mountPath = "/deps";
                            }
                          ];
                          readinessProbe = {
                            httpGet = {
                              path = "/";
                              port = 2718;
                            };
                            # generous: first readiness waits on the pip install
                            initialDelaySeconds = 15;
                            periodSeconds = 10;
                            failureThreshold = 30;
                          };
                        }
                      ];
                      volumes = [
                        {
                          name = "model";
                          configMap.name = "ipa-rfp-model";
                        }
                        {
                          name = "deps";
                          emptyDir = { };
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
                  name = "ipa-rfp-model";
                  namespace = namespace;
                };
                spec = {
                  selector.app = "ipa-rfp-model";
                  ports = [
                    {
                      port = 80;
                      targetPort = 2718;
                    }
                  ];
                };
              }
            ];
          };
      };
  };
}
