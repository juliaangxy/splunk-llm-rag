# Deployment

## 1. Validate templates

```bash
./utils/validate-stack.sh cloudformation/main.yaml
```

## 2. Upload Splunk app tarballs to S3

Place app packages in your license bucket under a prefix (default: splunk-apps/):

```bash
aws s3 cp ./apps/ s3://ai-splunk-license-bucket/splunk-apps/ --recursive --exclude "*" --include "*.tgz" --include "*.tar" --include "*.tar.gz" --include "*.spl"
```

## 2a. Upload Splunk Enterprise license file to S3

Place your Splunk Enterprise license file(s) in the local `licenses/` folder, then upload to the default discovery prefix:

```bash
find ./licenses -type f \( -name "*.License" -o -name "*.lic" \) -print0 | while IFS= read -r -d '' file; do aws s3 cp "$file" "s3://ai-splunk-license-bucket/licenses/$(basename "$file" | tr ' ' '-')"; done
```

If you want to install specific license files, set `LICENSE_KEY` explicitly, for example:

```bash
export LICENSE_KEY='Splunk-Enterprise-NFR-CY2026.License'
```

For multiple license files, provide a comma-separated list:

```bash
export LICENSE_KEY='licenses/stack-a.lic,licenses/stack-b.lic'
```

If `LICENSE_KEY` is empty, stage 07 auto-discovers and installs all `.lic`/`.License`
files under `LicenseS3Prefix` (default: `licenses/`).

## 2b. Optional: stage Ollama model bundles from Hugging Face into S3

If you want stage 04 to import Ollama models from S3 instead of pulling from Ollama Hub,
use the helper script below. It downloads a GGUF model from Hugging Face, creates an
Ollama `Modelfile`, and uploads the bundle to your Ollama model S3 prefix.

Example using Foundation-Sec:

```bash
./utils/upload-huggingface-ollama-model.sh \
  https://huggingface.co/fdtn-ai/Foundation-Sec-1.1-8B-Instruct-Q8_0-GGUF \
  ai-splunk-ai-bucket \
  models/huggingface/ollama/ \
  foundation-sec-8b
```

That creates an S3 bundle like:

```text
s3://ai-splunk-ai-bucket/models/huggingface/ollama/foundation-sec-8b/Modelfile
s3://ai-splunk-ai-bucket/models/huggingface/ollama/foundation-sec-8b/<gguf-file>
```

## 2c. Optional: stage Milvus compose artifact in S3 for bootstrap stage 05

If you want stage 05 to run `docker compose up` from an S3-hosted compose file,
upload it with the helper below. The utility downloads the compose artifact locally
first, then uploads it (plus any optional extra artifacts) to the shared AI artifacts bucket.

```bash
./utils/upload-milvus-compose-artifacts.sh \
  ai-splunk-ai-bucket \
  milvus/
```

By default this uploads:

```text
s3://ai-splunk-ai-bucket/milvus/milvus-docker-compose.yml
```

Optional: include extra artifact URLs that should be staged under the same S3 prefix:

```bash
./utils/upload-milvus-compose-artifacts.sh \
  ai-splunk-ai-bucket \
  milvus/ \
  https://raw.githubusercontent.com/splunk/splunk-mltk-container-docker/v5.2/beta_content/passive_deployment_prototypes/prototype_ollama_example/compose_files/milvus-docker-compose.yml \
  https://example.org/milvus.env
```

Stage 05 will fetch this path when `AiArtifactsBucket` is configured.
By default it syncs from `s3://AiArtifactsBucket/milvus/`.

## 2d. Optional: stage a Hugging Face embedding model for DSDL CPU inference

If you want bootstrap stage 09 to run a DSDL CPU inference container with a local
embedding model mount, upload the model into the shared AI artifacts bucket first:

```bash
./utils/upload-huggingface-embedding-model.sh \
  sentence-transformers/all-MiniLM-L6-v2 \
  ai-splunk-ai-bucket \
  models/huggingface/sentence-transformers/
```

That creates an S3 path like:

```text
s3://ai-splunk-ai-bucket/models/huggingface/sentence-transformers/all-MiniLM-L6-v2/
```

During stage 09, bootstrap syncs `s3://AI_ARTIFACTS_BUCKET/models/huggingface/sentence-transformers/all-MiniLM-L6-v2/`
to `/opt/splunk-ai/models/all-MiniLM-L6-v2` and starts container
`dsdl-cpu-inference` on `dsenv-network` mounting that directory at `/srv/app/model`.

Stage 09 also stages `minilm_embedding.py` into Splunk at:

```text
/opt/splunk/etc/apps/dsdl/local/blueprints/minilm_embedding.py
```

and mounts it inside the DSDL CPU container at:

```text
/srv/app/notebooks/custom/minilm_embedding.py
```

If you need a custom MLTK/DSDL integration script, start from:

```text
scripts/minilm_embedding.py
```

## 3. Update parameter file

Set required parameters in one of:
- cloudformation/parameters/dev.json
- cloudformation/parameters/staging.json
- cloudformation/parameters/prod.json

## 4. Deploy with AWS CLI

Required inputs from the CloudFormation template:
- KeyName (existing EC2 key pair name)
- LicenseBucket (S3 bucket storing Splunk license and app tar files)
- LicenseKey (optional: S3 object key for a single license file, or comma-separated keys for multiple licenses)
- AllowedSshCidr (required, no default)
- AllowedSplunkUiCidr (required, no default)
- SplunkAdminPassword (required)
- One of SplunkPackageUrl, SplunkPackageS3Key, or SplunkPackageS3Prefix

Additional deployment requirement:
- CFN_ARTIFACT_BUCKET (S3 bucket used by deploy-stack.sh for CloudFormation packaging)
- If unset, deployment falls back to LicenseBucket from the environment parameter file.

Non-sensitive defaults should live in cloudformation/parameters/dev.json.
Use environment variables only for sensitive values or one-off overrides.

For local deployments, edit `cloudformation/parameters/dev.env` and let `deploy-stack.sh`
auto-load it. That file now holds the required CIDRs, password, common buckets, package
prefixes, image tags, and the shared-infrastructure defaults used by the guide below.

For MLTK containerized runtimes, `dev.env` also controls the generated
`$SPLUNK_HOME/etc/apps/mltk-container/local/containers.conf` entries:

- `CONTAINER_IMAGE_PROFILES_JSON`
- `SPLUNK_LLM_RAG_IMAGE`
- `DSDL_CPU_INFERENCE_IMAGE`
- `SPLUNK_MLTK_GPU_IMAGE`
- `SPLUNK_LLM_RAG_HOST_PORT`
- `DSDL_CPU_INFERENCE_PORT`
- `SPLUNK_MLTK_GPU_HOST_PORT`
- `MLTK_CONTAINER_EXTERNAL_HOST`

During stage 09, bootstrap now writes those values into independent `containers.conf`
stanzas and reloads Splunk so the `mltk-container` app can start the configured
container profiles without hardcoded image names or ports.

`CONTAINER_IMAGE_PROFILES_JSON` is the preferred multi-container format. It accepts a JSON
array of profile objects with fields such as:

- `role`: `llm_rag`, `cpu_container`, or `gpu_container`
- `name`: stanza name written into `containers.conf`
- `source_image`: source image used by upload helpers and as a runtime fallback when `image` is empty
- `image`: optional explicit runtime image URI for the app to pull
- `host_port`: external host port for `api_url_external`
- `mode`: defaults to `DEV`
- `runtime`: defaults to `None`
- `shared_repository`: optional shared ECR routing hint, usually `llm_rag` or `mltk_gpu`

When `CONTAINER_IMAGE_PROFILES_JSON` is set, the upload helper prefers it over
`DOCKER_SOURCE_IMAGES`, and stage 09 uses it to generate every container profile.

Typical local flow:

```bash
./utils/push-docker-images-to-ecr.sh
./scripts/deploy-stack.sh dev ap-southeast-1
```

If you need a one-off override, export it in your shell first; `dev.env` remains the
default place for the reusable values.

Shared infrastructure is still handled by `deploy-stack.sh`. When
`PROVISION_SHARED_INFRASTRUCTURE=true`, it creates the shared stack first, stages the
Step 2 uploads, and then deploys the main stack using the shared outputs. Set the shared
flags in `dev.env` when you want to use that path.

    Splunk RPM staging behavior:

    - `deploy-stack.sh` uses `wget` to download the RPM from `SPLUNK_PACKAGE_URL`.
    - If `wget` is unavailable, it automatically falls back to `curl -fL`.
    - If `SPLUNK_PACKAGE_URL` is not set, shared mode defaults to:
      `https://download.splunk.com/products/splunk/releases/10.4.1/linux/splunk-10.4.1-5a009d941268.x86_64.rpm`
    - The RPM is uploaded to the shared license bucket under `SplunkPackageS3Prefix`.
    - If `SPLUNK_PACKAGE_S3_KEY` is not set, deploy-stack sets it automatically to the uploaded key for the current deployment run.

    Optional flags for this phase:

    - `STAGE_STEP2_UPLOADS_AFTER_SHARED=false` (skip all automatic Step 2 uploads)
    - `SKIP_STEP2_UPLOADS_AFTER_SHARED=true` (equivalent skip-style alias)
    - `UPLOAD_OLLAMA_MODEL_AFTER_SHARED=false`
    - `UPLOAD_MILVUS_ARTIFACTS_AFTER_SHARED=false`
    - `UPLOAD_EMBEDDING_MODEL_AFTER_SHARED=false`

4. Shared ECR images are seeded automatically when `PROVISION_SHARED_INFRASTRUCTURE=true`:

  `deploy-stack.sh` now pushes source images into the shared ECR repository output(s) using derived tags.

    - Default source images are:
      - `splunk/mltk-container-golden-gpu:5.2.3`
      - `splunk/mltk-container-ubi-llm-rag:5.2.3`
      - `splunk/mltk-container-golden-cpu:5.2.3`
    - You can override sources with `DOCKER_SOURCE_IMAGES` (comma-separated).
    - In shared mode, `ECR_REPOSITORY_NAME` is ignored for this auto-seeding step so images are always pushed to the shared stack repository output(s).

    It also sets main stack image parameters from shared stack outputs.
    Both output keys may resolve to the same shared repository URI (single-repo mode).
    Image tags are derived dynamically from source images with this pattern:

    - `<source-image-name>-<source-tag>`

    Examples:

    - `SPLUNK_MLTK_GPU_IMAGE=<MltkGpuRepositoryUri>:mltk-container-golden-gpu-5.2.3`
    - `SPLUNK_LLM_RAG_IMAGE=<LlmRagRepositoryUri>:mltk-container-ubi-llm-rag-5.2.3`
    - `DSDL_CPU_INFERENCE_IMAGE=<MltkGpuRepositoryUri>:mltk-container-golden-cpu-5.2.3`

    In shared-infrastructure mode, `deploy-stack.sh` now passes
    `DSDL_CPU_INFERENCE_IMAGE` through CloudFormation into the EC2 bootstrap
    environment automatically, so new instances use the shared ECR golden-cpu
    image instead of the public fallback.

    During bootstrap stage 09, if `DSDL_CPU_INFERENCE_IMAGE` is unset,
    `09-configure.sh` derives it automatically from `SPLUNK_MLTK_GPU_IMAGE`
    (same repository, tag pattern `mltk-container-golden-cpu-<version>`).
    If derivation is not possible, stage 09 falls back to
    `splunk/dsdl-images:deep-learning-backbone-cpu`.

4a. Optional: build and push DSDL-compatible images from source into shared ECR:

  If you need to build images yourself (for example when a public image is unavailable),
  use `utils/build-and-push-dsdl-images-to-ecr.sh`.

  This script:

  - clones `https://github.com/splunk/splunk-mltk-container-docker`
  - builds `golden-gpu` and `ubi-llm-rag`
  - builds `golden-cpu` by default (useful as a DSDL CPU image fallback)
  - pushes all built images into your target ECR repository
  - prints final image URIs to export for deployment/bootstrap

  Example:

```bash
export REGION=ap-southeast-1
export ENVIRONMENT=dev
export SHARED_STACK_NAME="splunk-ai-shared-${ENVIRONMENT}"

TARGET_REPO_URI="$(aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${SHARED_STACK_NAME}" \
  --query 'Stacks[0].Outputs[?OutputKey==`MltkGpuRepositoryUri`].OutputValue' \
  --output text)"

./utils/build-and-push-dsdl-images-to-ecr.sh "${REGION}" "${TARGET_REPO_URI}" 5.2.3 master
```

  Expected image URIs produced by that flow:

  - `SPLUNK_MLTK_GPU_IMAGE=${TARGET_REPO_URI}:mltk-container-golden-gpu-5.2.3`
  - `SPLUNK_LLM_RAG_IMAGE=${TARGET_REPO_URI}:mltk-container-ubi-llm-rag-5.2.3`
  - `DSDL_CPU_INFERENCE_IMAGE=${TARGET_REPO_URI}:mltk-container-golden-cpu-5.2.3`

  To skip building/pushing golden-cpu:

```bash
BUILD_GOLDEN_CPU=false ./utils/build-and-push-dsdl-images-to-ecr.sh "${REGION}" "${TARGET_REPO_URI}" 5.2.3 master
```

4b. Verify shared ECR tags before rerunning stage 09:

  If bootstrap stage 09 failed due to missing image manifest, verify the expected tags exist in the target repository first.

```bash
export REGION=ap-southeast-1
export ENVIRONMENT=dev
export SHARED_STACK_NAME="splunk-ai-shared-${ENVIRONMENT}"

TARGET_REPO_URI="$(aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${SHARED_STACK_NAME}" \
  --query 'Stacks[0].Outputs[?OutputKey==`MltkGpuRepositoryUri`].OutputValue' \
  --output text)"

aws ecr describe-images \
  --region "${REGION}" \
  --repository-name "${TARGET_REPO_URI#*/}" \
  --query 'imageDetails[].imageTags[]' \
  --output text | tr '\t' '\n' | sort -u
```

  Expected tags include:

  - `mltk-container-golden-gpu-5.2.3`
  - `mltk-container-ubi-llm-rag-5.2.3`
  - `mltk-container-golden-cpu-5.2.3`

  Then rerun stage 09 on EC2:

```bash
sudo bash -lc 'source /opt/splunk-ai/bootstrap.env && /opt/splunk-ai/scripts/09-configure.sh'
```

`deploy-stack.sh` uses `CFN_ARTIFACT_BUCKET` for both stacks when set,
with distinct prefixes in the format:

```text
<stack-name>-dd-MM-yyyy-HH-mm
```

If `CFN_ARTIFACT_BUCKET` is unset, it falls back to `LicenseBucket`.

Tail bootstrap logs on the EC2 instance (SSM):

If you see `SessionManagerPlugin is not found` on macOS, install it first:

```bash
brew install --cask session-manager-plugin
session-manager-plugin --version
```

```bash
export STACK_NAME="splunk-ai-${ENVIRONMENT}"
export INSTANCE_ID="$(aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
  --output text)"

aws ssm start-session \
  --region "${REGION}" \
  --target "${INSTANCE_ID}" \
  --document-name AWS-StartInteractiveCommand \
  --parameters 'command=["sudo tail -f /var/log/splunk-ai-userdata.log /var/log/cloud-init-output.log"]'
```

When manually rerunning a stage script on EC2, source persisted bootstrap env first:

```bash
sudo bash -lc 'source /opt/splunk-ai/bootstrap.env && /opt/splunk-ai/scripts/07-license.sh'
```

Fallback when Session Manager plugin is unavailable (non-interactive last 200 lines):

```bash
aws ssm send-command \
  --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo tail -n 200 /var/log/splunk-ai-userdata.log /var/log/cloud-init-output.log"]' \
  --query 'Command.CommandId' \
  --output text
```

For rapid re-testing, delete the environment stack and wait until deletion completes:

```bash
./utils/delete-stack.sh "${ENVIRONMENT}" "${REGION}"
```

Delete only the shared infrastructure stack:

```bash
./utils/delete-stack.sh "${ENVIRONMENT}" "${REGION}" --shared
```

Delete both main and shared stacks:

```bash
./utils/delete-stack.sh "${ENVIRONMENT}" "${REGION}" --all
```

Optional custom stack name:
```bash
./utils/delete-stack.sh "${ENVIRONMENT}" "${REGION}" my-custom-stack
```

To update baseline settings, edit cloudformation/parameters/dev.json directly
(for example KeyName, LicenseBucket, LicenseKey, CIDRs, image names, S3 prefixes,
RAG model name, and snapshot toggle).

This script will:
- Use your selected region
- Retrieve the latest NVIDIA DLAMI ID for that region
- Package CloudFormation templates to S3 before deployment
- Use `CFN_ARTIFACT_BUCKET` for both shared and main stack packaging when set, with unique prefixes per stack in the format `<stack-name>-dd-MM-yyyy-HH-mm`
- Upload bootstrap scripts to S3 and pass both bucket/key plus a presigned BootstrapScriptsUrl fallback
- Pass AmiId into CloudFormation automatically
- Read non-sensitive deployment settings from cloudformation/parameters/<env>.json
- Require SPLUNK_ADMIN_PASSWORD from environment
- Allow Splunk UI (8000) and LLM endpoint (11434) from your IP by default
- Keep LLM endpoint (11434) reachable from internal app CIDR (defaults to VPC CIDR)
- Default Docker, DSDL, Ollama, and Milvus CIDRs to the VPC CIDR
- Provision S3 gateway and ECR (api+dkr) VPC endpoints in the network stack so EC2 reaches S3/ECR over VPC endpoints instead of traversing IGW for those services
- Configure Splunk installation source from env override or parameter file
- Optionally install Splunk from LICENSE_BUCKET/SPLUNK_PACKAGE_S3_KEY (takes precedence over URL source)
- If exact key is not set, auto-discovers an .rpm under LICENSE_BUCKET/SPLUNK_PACKAGE_S3_PREFIX
- Optionally sync Ollama model bundles from AI_ARTIFACTS_BUCKET/OLLAMA_MODEL_S3_PREFIX and import them with `ollama create`
- During stage 05, attempt to sync Milvus artifacts from `s3://AI_ARTIFACTS_BUCKET/milvus/` and run `docker compose up -d` from `milvus-docker-compose.yml` (or `docker-compose.yml` / `docker-compose.yaml`) in that synced bundle
- If the S3 Milvus compose artifact is not present, stage 05 falls back to the built-in Milvus compose definition
- Docker daemon remote API and NVIDIA runtime configuration are now applied in stage 01 before containerized services start, so Milvus is not invalidated later by a Docker restart
- During stage 09, sync embedding model artifacts from `s3://AI_ARTIFACTS_BUCKET/models/huggingface/sentence-transformers/all-MiniLM-L6-v2/` and stage `minilm_embedding.py` to Splunk (`/opt/splunk/etc/apps/dsdl/local/blueprints/`) before writing `mltk-container/local/containers.conf`
- During stage 09, if a Milvus compose file exists at `/opt/splunk-ai/milvus/docker-compose.yaml`, the script reconciles that stack after Docker checks before verifying Milvus readiness
- Install apps from LICENSE_BUCKET via SPLUNK_APP_S3_KEYS or SPLUNK_APPS_S3_PREFIX during stage 08
- Run a local Ansible playbook after app install in stage 08 to apply app configuration defaults from README requirements
- Generate `mltk-container/local/containers.conf` from the configured image and port env vars, then attempt a lightweight Splunk refresh first; stage 09 only falls back to a full restart if those direct local `.conf` updates are not applied cleanly
- EC2 instance IAM includes ECR auth/pull permissions so stage 09 can login and pull private ECR images when SPLUNK_*_IMAGE points at ECR URIs
- If optional image registries are private and unauthenticated, leave SPLUNK_MLTK_GPU_IMAGE and SPLUNK_LLM_RAG_IMAGE empty to skip container startup
- When PROVISION_SHARED_INFRASTRUCTURE=true, deploy-stack.sh automatically runs Step 2 S3 uploads into newly created shared buckets (apps, licenses, Ollama model bundle, Milvus artifact, embedding model) unless disabled by upload flags
- When PROVISION_SHARED_INFRASTRUCTURE=true, deploy-stack.sh automatically seeds required MLTK/LLM-RAG images into a single created shared ECR repository (different tags) and wires those image URIs into main stack deployment
- Set PROVISION_SHARED_INFRASTRUCTURE=true to have deploy-stack.sh create the separate shared-infrastructure stack before the main stack
- When PROVISION_SHARED_INFRASTRUCTURE=true, set SHARED_RESOURCE_NAME_PREFIX to a user-controlled lowercase base name; shared-infrastructure appends a 5-character unique suffix to generated bucket and repository names
- If PROVISION_SHARED_INFRASTRUCTURE=false, deploy-stack.sh skips the shared stack and uses bucket values already configured in parameter file or environment overrides
- Wait for bootstrap completion before CloudFormation marks the EC2 resource complete (success/failure is signaled from instance userdata)
- Set REQUIRE_BOOTSTRAP_SUCCESS=false only for debug/test loops when you want CloudFormation to continue even if bootstrap.sh fails

CloudFormation parameters with defaults if not specified in your parameter file:
- EnvironmentName (defaults to dev)
- VpcCidr (defaults to 10.0.0.0/16)
- PublicSubnetCidr (defaults to 10.0.1.0/24)
- InstanceType (defaults to g6.4xlarge; supported values: g6.4xlarge, g5.4xlarge, g4dn.4xlarge)
- RootVolumeSize (defaults to 80)
- SplunkAppS3Keys (defaults to empty)
- SplunkAppsS3Prefix (defaults to splunk-apps/)
- RagModelName (defaults to empty)
- CreateSnapshotOnSuccess (defaults to true)
- RequireBootstrapSuccess (defaults to true)
- LicenseS3Prefix (defaults to licenses/)
- AiArtifactsBucket (defaults to empty)
- OllamaModelS3Prefix (defaults to models/huggingface/ollama/)
- SplunkPackageUrl (defaults to empty)
- SplunkPackageS3Key (defaults to empty)
- SplunkPackageS3Prefix (defaults to splunk-rpms/)
- SkipSplunkAppsBootstrap (defaults to false)

Deploy script environment flags (not CloudFormation template parameters):
- PROVISION_SHARED_INFRASTRUCTURE (defaults to false)
- SHARED_RESOURCE_NAME_PREFIX (required when PROVISION_SHARED_INFRASTRUCTURE=true)
- SHARED_STACK_NAME (defaults to splunk-ai-shared-<env>)
- PROVISION_SHARED_S3_BUCKETS (defaults to value from parameter file, else true)
- PROVISION_SHARED_ECR_REPOSITORIES (defaults to value from parameter file, else true)
- SHARED_LICENSE_BUCKET_NAME (defaults to LicenseBucket value from parameter file)
- SHARED_AI_ARTIFACTS_BUCKET_NAME (defaults to AiArtifactsBucket value from parameter file)
- STAGE_STEP2_UPLOADS_AFTER_SHARED (defaults to true)
- SKIP_STEP2_UPLOADS_AFTER_SHARED (defaults to false; forces STAGE_STEP2_UPLOADS_AFTER_SHARED=false)
- UPLOAD_OLLAMA_MODEL_AFTER_SHARED (defaults to true)
- UPLOAD_MILVUS_ARTIFACTS_AFTER_SHARED (defaults to true)
- UPLOAD_EMBEDDING_MODEL_AFTER_SHARED (defaults to true)

CloudFormation parameters without defaults that must be set before deploy:
- KeyName
- LicenseBucket
- AllowedSshCidr
- SplunkAdminPassword
- SplunkPackageUrl or SplunkPackageS3Key or SplunkPackageS3Prefix
- AmiId (auto-provided by ./scripts/deploy-stack.sh)

Splunk app source behavior during stage 08-apps.sh:
- Uses LICENSE_BUCKET for all app package reads
- If SPLUNK_APP_S3_KEYS is set, installs keys in listed order
- If SPLUNK_APP_S3_KEYS is empty, discovers .tgz, .tar, .tar.gz, and .spl under SPLUNK_APPS_S3_PREFIX
- If a package fails download or tar validation, logs a warning and continues
- App configuration is deferred to stage 09-configure.sh; stage 08 keeps app installation on the reload-safe path and avoids full daemon restarts
- If SKIP_SPLUNK_APPS_BOOTSTRAP=true, stage 08-apps.sh is skipped during bootstrap

Post-install configuration behavior during stage 09-configure.sh:
- Applies Docker and optional container runtime configuration
- Detects all configured `SPLUNK_*_IMAGE` environment variables and explicitly runs `docker pull` for each configured URI
- For private ECR image URIs, stage 09 uses the Docker ECR credential helper when available (falls back to `aws ecr get-login-password` + `docker login` if needed) before pulling
- If Docker daemon remote API configuration is already present from stage 01, stage 09 skips restarting Docker
- If `/opt/splunk-ai/milvus/docker-compose.yaml` exists, stage 09 runs `docker compose up -d` for that stack before Milvus verification
- Runs scripts/configure-splunk-apps.yml to apply MLTK sharing and DSDL setup defaults
- Writes `$SPLUNK_HOME/etc/apps/mltk-container/local/containers.conf` using the configured image names, external host, and unique host ports
- Uses `SPLUNK_LLM_RAG_HOST_PORT` (default `5001`), `DSDL_CPU_INFERENCE_PORT` (default `5002`), and `SPLUNK_MLTK_GPU_HOST_PORT` (default `5003`) to keep each profile on its own external port
- Requests a lightweight Splunk refresh after configuration changes so the `mltk-container` app can apply the updated profiles, but still falls back to a full restart if the direct local `.conf` edits are not picked up cleanly

License health behavior during stage 07-license.sh:
- Validates Splunk health with reload-safe reconciliation before importing licenses and only starts Splunk if it is currently down

License source behavior during stage 07-license.sh:
- If LICENSE_KEY is set, installs exactly those key(s) in listed order
- If LICENSE_KEY is empty, discovers and installs all .lic/.License files under LICENSES_S3_PREFIX

Optional explicit AMI override:

```bash
./scripts/deploy-stack.sh dev us-east-1 ami-0123456789abcdef0
```

## 5. Post-config snapshot behavior

After successful configuration, stage 10-snapshot.sh creates an EBS snapshot of the instance root volume automatically.

To disable this behavior for a deployment, set:

```bash
export CREATE_SNAPSHOT_ON_SUCCESS=false
```
