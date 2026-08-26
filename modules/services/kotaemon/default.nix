# kin/kotaemon — kotaemon RAG web UI (Cinnamon/kotaemon) behind the Cloudflare
# Tunnel + Access, serving the ipa-coal-analysis document corpus.
#
# State (sqlite + Chroma vectors + LanceDB docstore + raw files) lives on a
# Longhorn PVC mounted at /app/ktem_app_data. It is seeded by migrating the
# locally-verified state from ipa-coal-analysis (scripts/migrate-kotaemon-state.sh
# there) rather than starting fresh — the local DB already carries the
# gpt-5.6 temperature fix and the curated uploads. A fresh PVC would re-seed
# from flowsettings defaults (gpt-4o-mini, temperature 0, which gpt-5.6
# rejects) and need manual sqlite surgery.
#
# The OpenAI API key is a clan var (prompted once: `clan vars generate`),
# synced into the kotaemon-openai Secret at boot — same shape as the
# cloudflared tunnel token. It never lands in a manifest.
#
# Exposure (manual, Cloudflare Zero Trust dashboard — same as hello):
#   1. Tunnel public hostname:  rag.<domain> ->
#        http://kotaemon.kotaemon.svc.cluster.local:80
#   2. Access application on rag.<domain> with an email allow-list.
#      Do NOT skip step 2: kotaemon ships with admin/admin.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/kotaemon";
  manifest.description = "kotaemon RAG web UI behind the Cloudflare Tunnel.";
  manifest.categories = [ "Science" ];

  roles.default = {
    description = "Deploy the kotaemon origin from this server.";
    perInstance =
      { ... }:
      {
        nixosModule =
          { config, ... }:
          let
            # main-lite is enough: pypdf loaders + on x86_64 it includes MS
            # GraphRAG (the arm64 build doesn't). Swap to a derived image if
            # Docling/nano-graphrag are ever wanted.
            image = "ghcr.io/cinnamon/kotaemon:main-lite";
            namespace = "kotaemon";
            secretName = "kotaemon-openai";

            keyPath = config.clan.core.vars.generators.kotaemon-openai-key.files."api-key".path;
          in
          {
            # OpenAI API key — bearer credential, never lands in a manifest.
            clan.core.vars.generators.kotaemon-openai-key = {
              prompts.api-key = {
                description = "OpenAI API key for kotaemon (sk-...)";
                type = "hidden";
                persist = true;
              };
            };

            services.k3s.manifests.kotaemon.content = [
              {
                apiVersion = "v1";
                kind = "Namespace";
                metadata.name = namespace;
              }
              {
                apiVersion = "v1";
                kind = "PersistentVolumeClaim";
                metadata = {
                  name = "kotaemon-data";
                  namespace = namespace;
                };
                spec = {
                  accessModes = [ "ReadWriteOnce" ];
                  storageClassName = "longhorn";
                  # local state hit 17Gi at ~500 docs on 3-large embeddings;
                  # 3-small halves vector growth. Longhorn volumes can be
                  # expanded later.
                  resources.requests.storage = "50Gi";
                };
              }
              {
                apiVersion = "apps/v1";
                kind = "Deployment";
                metadata = {
                  name = "kotaemon";
                  namespace = namespace;
                };
                spec = {
                  replicas = 1;
                  # sqlite + LanceDB on one RWO volume: never two pods at once
                  strategy.type = "Recreate";
                  selector.matchLabels.app = "kotaemon";
                  template = {
                    metadata.labels.app = "kotaemon";
                    spec = {
                      automountServiceAccountToken = false;
                      containers = [
                        {
                          name = "kotaemon";
                          inherit image;
                          env = [
                            {
                              name = "GRADIO_SERVER_NAME";
                              value = "0.0.0.0";
                            }
                            {
                              name = "GRADIO_SERVER_PORT";
                              value = "7860";
                            }
                            # only consulted when seeding a fresh DB; existing
                            # state in sql.db wins
                            {
                              name = "OPENAI_CHAT_MODEL";
                              value = "gpt-5.6-luna";
                            }
                            {
                              name = "OPENAI_EMBEDDINGS_MODEL";
                              value = "text-embedding-3-small";
                            }
                            {
                              name = "OPENAI_API_KEY";
                              valueFrom.secretKeyRef = {
                                name = secretName;
                                key = "api-key";
                              };
                            }
                          ];
                          ports = [ { containerPort = 7860; } ];
                          volumeMounts = [
                            {
                              name = "data";
                              mountPath = "/app/ktem_app_data";
                            }
                          ];
                          resources = {
                            requests.memory = "2Gi";
                            # replaces the local docker --memory 10g cap; a
                            # wedged/ballooning parse gets OOM-killed and the
                            # pod restarts instead of starving the node
                            limits.memory = "8Gi";
                          };
                          readinessProbe = {
                            httpGet = {
                              path = "/";
                              port = 7860;
                            };
                            initialDelaySeconds = 30;
                            periodSeconds = 10;
                            failureThreshold = 18;
                          };
                          livenessProbe = {
                            httpGet = {
                              path = "/";
                              port = 7860;
                            };
                            # generous: catches crashes/OOM wedges, not slow
                            # parses (the UI stays responsive during those)
                            initialDelaySeconds = 120;
                            periodSeconds = 30;
                            timeoutSeconds = 10;
                            failureThreshold = 10;
                          };
                        }
                      ];
                      volumes = [
                        {
                          name = "data";
                          persistentVolumeClaim.claimName = "kotaemon-data";
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
                  name = "kotaemon";
                  namespace = namespace;
                };
                spec = {
                  selector.app = "kotaemon";
                  ports = [
                    {
                      port = 80;
                      targetPort = 7860;
                    }
                  ];
                };
              }
            ];

            # Sync the sops-decrypted key into a k8s Secret at boot — same
            # shape as cloudflared-token.
            systemd.services.kotaemon-openai-key = {
              description = "Sync the OpenAI API key into the kotaemon namespace";
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
                  --from-file=api-key=${keyPath} \
                  --dry-run=client -o yaml | k3s kubectl apply -f -
              '';
            };
          };
      };
  };
}
