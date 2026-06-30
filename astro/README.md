# Astro project — `aws-re-dr`

Astro project deployed to the Remote Execution agent in each region of the [aws-re-dr](../) cross-region DR template. DAGs, the agent Dockerfile, and Python/OS dependencies live here.

## Layout

- `dags/` — DAG source. `exampledag.py` is included as a smoke test.
- `Dockerfile` — base image used by `astro dev start` for local Airflow.
- `Dockerfile.client` — generated and edited during `astro remote deploy`; builds the **remote-agent** image. Adds the Amazon provider (`apache-airflow-providers-amazon[s3fs]`) so S3 XCom and remote logging work.
- `requirements.txt` / `requirements-client.txt` — Python dependencies for local and remote-agent images respectively.
- `packages.txt` / `packages-client.txt` — OS-level packages (apt) for local and remote-agent images.
- `include/`, `plugins/` — standard Astro project directories (empty by default).
- `airflow_settings.yaml` — local-only connections/variables/pools for `astro dev start`. Never deployed.
- `tests/` — DAG integrity tests.

## Local development

```bash
astro dev start
```

Opens the Airflow UI at http://localhost:8080. Connections defined in `airflow_settings.yaml` are loaded automatically.

## Deploying to the remote agent

The remote agent runs out of each region's ECR repository, not the Astronomer image registry — `astro deploy` is **not** used here. From this directory, run `astro remote deploy` once per region as described in [../infra/README.md](../infra/README.md#step-4-build-and-push-your-custom-agent-image-per-region):

```bash
astro login
aws ecr get-login-password --region <region> | \
  docker login --username AWS --password-stdin <region.ecr_repo_url>
astro remote deploy --platform linux/amd64
```

When prompted for the registry URL, use the `ecr_repo_url` from `terraform output -json {primary,failover} | jq -r .ecr_repo_url`.

Note the image tag returned — it goes into [../values.yaml](../values.yaml) for the Helm install.
