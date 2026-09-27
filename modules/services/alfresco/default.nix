# Alfresco Community test instance. No public tunnel; access via LAN mDNS.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/alfresco";
  manifest.description = "Alfresco Community document management test instance.";
  manifest.categories = [ "Office" ];

  roles.default.perInstance =
    { ... }:
    {
      nixosModule =
        { config, pkgs, ... }:
        let
          credentials = config.clan.core.vars.generators.alfresco.files;
        in
        {
          clan.core.vars.generators.alfresco = {
            files.password.secret = true;
            files.password-hash.secret = true;
            files."values.yaml".secret = true;
            runtimeInputs = [
              pkgs.openssl
              pkgs.glibc.bin
            ];
            script = ''
              openssl rand -hex 24 | tr -d '\n' > "$out/password"
              iconv -f UTF-8 -t UTF-16LE "$out/password" \
                | openssl dgst -provider legacy -md4 -binary \
                | od -An -tx1 | tr -d ' \n' > "$out/password-hash"
              cat > "$out/values.yaml" <<EOF
              global:
                search:
                  sharedSecret: $(openssl rand -hex 24)
              postgresql:
                auth:
                  password: $(openssl rand -hex 24)
              activemq:
                adminUser:
                  password: $(openssl rand -hex 24)
              EOF
            '';
          };

          services.k3s.manifests.alfresco.content = [
            {
              apiVersion = "v1";
              kind = "Namespace";
              metadata.name = "alfresco";
            }
            {
              apiVersion = "helm.cattle.io/v1";
              kind = "HelmChart";
              metadata = {
                name = "alfresco";
                namespace = "kube-system";
              };
              spec = {
                repo = "https://kubernetes-charts.alfresco.com/stable";
                chart = "alfresco-content-services";
                version = "10.8.0";
                targetNamespace = "alfresco";
                timeout = "20m";
                valuesContent = builtins.readFile ./values.yaml;
                valuesSecrets = [
                  {
                    name = "alfresco-helm-values";
                    keys = [ "values.yaml" ];
                  }
                ];
              };
            }
          ];

          systemd.services.alfresco-credentials = {
            description = "Sync Alfresco credentials into Kubernetes";
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
              k3s kubectl create namespace alfresco --dry-run=client -o yaml | k3s kubectl apply -f -
              k3s kubectl -n alfresco create secret generic alfresco-admin \
                --from-file=password=${credentials.password.path} \
                --from-file=ADMIN_PASSWORD_HASH=${credentials.password-hash.path} \
                --dry-run=client -o yaml | k3s kubectl apply -f -
              k3s kubectl -n kube-system create secret generic alfresco-helm-values \
                --from-file=values.yaml=${credentials."values.yaml".path} \
                --dry-run=client -o yaml | k3s kubectl apply -f -
            '';
          };

          services.avahi.publish.userServices = true;
          systemd.services.avahi-alias-alfresco = {
            description = "mDNS alias alfresco.local -> atlas";
            after = [ "avahi-daemon.service" ];
            requires = [ "avahi-daemon.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "${pkgs.avahi}/bin/avahi-publish -a -R alfresco.local 10.10.3.100";
              Restart = "always";
              RestartSec = 5;
            };
          };
        };
    };
}
