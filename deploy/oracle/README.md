# Oracle demo

Resource Manager creates the infrastructure. Run Command deploys Docker Compose releases. Bastion provides temporary interactive access.

## Setup

Install the SDK:

```sh
python3 -m venv .venv/oracle
.venv/oracle/bin/pip install -r deploy/oracle/requirements.txt
export ORACLE_PYTHON="$PWD/.venv/oracle/bin/python"
```

Use an OCI profile in `~/.oci/config`, selecting the tenancy's home region (`eu-amsterdam-1` for this account). For a temporary local login, install the [Oracle CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) and run:

```sh
oci session authenticate --region eu-amsterdam-1 --profile-name neu-zeit
export OCI_PROFILE=neu-zeit
```

Complete the login in your browser. The temporary credentials belong to your Oracle user; SSH keys do not grant Oracle permissions. Renew an expired login before another command. An existing API signing key profile also works.

In [Oracle Cloud Shell](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cloudshellintro.htm), the controller uses the existing authenticated session automatically. No separate login or API key is needed.

The initial operator needs permission to create a child compartment, its compute/network/storage/Bastion resources and IAM policies, and a tenancy dynamic group; manage Resource Manager and Run Command; and read regional allocations for the free-capacity check. Set `OCI_COMPARTMENT_ID` to choose a parent compartment instead of the tenancy root. Servers use instance identities, without your API key or browser credentials.

For GitHub Actions, provision `access/main.tf` once through Resource Manager with `region`, `tenancy_ocid` and an API signing public key. It creates a separate API-only user, a deployment parent compartment and permissions for demo resources, tenancy dynamic groups and allocation inspection. Store its `config` output and private key in repository secrets `OCI_CONFIG` and `OCI_API_KEY`; set `OCI_COMPARTMENT_ID` to its compartment output. The workflow supplies `key_file`. Use **Deploy Oracle demo** or **Undeploy Oracle demo**.

## Commands

Run the same commands from the project directory in a local terminal (OCI profile) or browser-based Oracle Cloud Shell (existing login). For a GitHub-managed demo, export the repository's `OCI_COMPARTMENT_ID` value first.

```sh
bash deploy/oracle/demo.sh deploy --revision HEAD
bash deploy/oracle/demo.sh console
bash deploy/oracle/demo.sh console --tool iex
bash deploy/oracle/demo.sh console --role database --tool psql
bash deploy/oracle/demo.sh undeploy
```

Deploy uses a committed revision. First deploy creates two servers and stable credentials. Repeat deploys preserve PostgreSQL, back it up, build the application, run migrations, and switch traffic after health checks. Failed startup restores the previous application. Migrations must remain compatible with that release.

Console creates a disposable local key and a Bastion session for your public IP, then removes the session and key on exit. Access expires after 30 minutes. One console session is allowed at a time. IP detection uses api.ipify.org; `--client-ip ADDRESS` overrides it. SSH is open only to Bastion's private endpoint. Operators have full server access and must be trusted.

Undeploy deletes servers, database data, backups, buckets, network, deployment IAM resources and the stack. CI access, its empty parent compartment, account credentials and Oracle audit records remain so another deploy can run. Failed cleanup retains state and can be retried. Missing hosts never trigger automatic database replacement. After an interrupted operation, inspect Resource Manager and Run Command; once all work has stopped, use `bash deploy/oracle/demo.sh unlock`.

## Limits and backups

The configuration uses two E2.1.Micro servers (1 GB each), two 50 GB disks, private buckets and free Bastion. Each host has 2 GB of swap on its existing disk; builds are slower on Micro. HTTP/HTTPS are public; PostgreSQL accepts only the application. The database has a public IP for outbound downloads, with no public ingress.

PostgreSQL dumps run daily and before deployment. Seven daily slots, at most 1 GiB each, bound storage; oversized backups fail. Restore with `pg_restore`. Check `systemctl status neu-zeit-backup.service` in the database console. Container logs rotate at three 10 MB files per container; deployment logs are in `/opt/neu-zeit/operation.log`.

The controller checks existing allocations and reserves 8 GiB within the stricter 10 GB Standard storage allowance. There is no paid fallback. Account-wide request and traffic limits still apply; Always Free capacity is not guaranteed and idle VMs can be reclaimed.

References: [Always Free limits](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm), [Run Command](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/runningcommands.htm), [Bastion](https://www.oracle.com/security/cloud-security/bastion/).
