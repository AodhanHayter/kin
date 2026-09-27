# Alfresco test deployment

Open [Alfresco Share](http://alfresco.local/share/) on the LAN. Log in as `admin`.
From this repository, retrieve the generated password:

```sh
devenv shell -- clan vars get atlas alfresco/password
```

The password is also in the `alfresco-admin` Kubernetes Secret in namespace `alfresco`.
Do not use `admin/admin`. The default password does not work.

Atlas publishes `alfresco.local` through mDNS, which resolves names on the local network.
If your computer cannot resolve it, add `10.10.3.100 alfresco.local` to its hosts file.
There is no public tunnel route for this application.
HTTP is unencrypted. Use only test documents and the trusted LAN.

## Deployment

The `kin/alfresco` service in [default.nix](default.nix) runs on Atlas.
It installs the official `alfresco-content-services` Helm chart, pinned to `10.8.0`, through the k3s Helm controller.
The [values file](values.yaml) selects Community Edition and the existing Traefik controller.
It follows the [official deployment guide](https://alfresco.github.io/acs-deployment/docs/helm/desktop-deployment.html).

The repository runs Community `26.2.0`. Share runs `26.2.2`.
Enterprise-only applications, including Control Center, are disabled.
Elasticsearch provides full-text search. The five transform services provide document previews.

Longhorn stores the repository (20 GiB), PostgreSQL (8 GiB), search index (8 GiB), and ActiveMQ (20 GiB).
Each component has one instance. This deployment is not highly available and has no dedicated backup schedule.
Longhorn replication is not a backup. Do not store irreplaceable documents.

Inside `devenv shell`, deploy changes from the repository root:

```sh
clan vars generate atlas --generator alfresco
clan machines update atlas --build-host localhost
```

The build host must run x86_64 Linux. Comin also deploys changes pushed to `master`.
The generator creates encrypted credentials for the admin, database, broker, and search connection.
Do not regenerate these credentials after initialization without a password migration.
The repository uses its configured admin hash only during initial database creation.
Secret keys used as repository properties must be valid shell variable names, such as `ADMIN_PASSWORD_HASH`.

## Run access tests

You need Python 3, access to the LAN endpoint, and SSH access to Atlas.
From the repository root, run:

```sh
export ALFRESCO_PASSWORD="$(ssh root@atlas.local 'k3s kubectl -n alfresco get secret alfresco-admin -o jsonpath="{.data.password}"' | base64 -d)"
python3 tests/alfresco-smoke.py
unset ALFRESCO_PASSWORD
```

The test creates temporary documents and a read-only user, then removes them.
It tests these operations:

- Reject anonymous access and incorrect or factory-default passwords.
- Log in through the API and the Share form, then load the authenticated dashboard.
- Upload and download identical document bytes.
- Permit a Consumer to read, but reject edits and deletion.
- Update content and retain version history.
- Generate and download a PDF preview.
- Find uploaded content through full-text search.
- Remove temporary data and revoke the API ticket.

All tests passed on 2026-09-27.
A separate test replaced the PostgreSQL and repository pods, then downloaded the same original bytes and PDF preview.
The retained `Alfresco deployment verification.txt` document is in the admin user's My Files. You can delete it.

## Inspect runtime state

From a computer with SSH access to Atlas, inspect the application:

```sh
ssh root@atlas.local 'k3s kubectl -n alfresco get pods,pvc,ingress'
ssh root@atlas.local 'k3s kubectl -n kube-system get helmchart alfresco'
ssh root@atlas.local 'k3s kubectl -n alfresco logs deploy/alfresco-alfresco-repository --tail=50'
```

Expect 11 ready pods and four bound persistent volume claims.
The API Explorer is at [alfresco.local/api-explorer/](http://alfresco.local/api-explorer/).
Search can lag writes while the batch indexer catches up.

Initial deployment exposed two stale iSCSI records on Apollo with an unsupported `node.session.conn_reopen_log_freq` setting.
Removing only that setting restored volume attachment. No volume data changed.
Copies of the original records remain in `/root/alfresco-iscsi-backup-20260927` on Apollo.
