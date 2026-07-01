# FIPS-Compliant Docker Images for the Curity Identity Server

[![Quality](https://img.shields.io/badge/quality-production-green)](https://curity.io/resources/code-examples/status/)
[![Availability](https://img.shields.io/badge/availability-binary-blue)](https://curity.io/resources/code-examples/status/)

This repository builds FIPS 140-compliant multi-arch Docker images of the [Curity Identity Server](https://curity.io) on top of Ubuntu 22.04 with the FIPS-validated OpenSSL provider enabled via Ubuntu Pro.

Images are built for both `linux/amd64` and `linux/arm64` and the container runs `idsvr --fips-mode`.

# Repository layout

* `versions.yaml` — list of Curity Identity Server versions to build, with their commit hash and Jenkins build numbers per arch.
* `docker/Dockerfile` — the single Dockerfile used for all versions; `VERSION`, `COMMIT`, and `TARGETARCH` are passed as build args.
* `docker/first-run` — first-run script copied into the image.
* `update-multiplatform-images.sh` — daily rebuild script (see below).

# Prerequisites

* `docker` with `buildx`
* `aws` CLI, authenticated for the `curity-idsvr-build-artifacts` S3 bucket
* `yq` (mikefarah) and `jq`
* An Ubuntu Pro **guest token** exported as `TOKEN`:

  ```bash
  export TOKEN=$(sudo pro api u.pro.attach.guest.get_guest_token.v1 | jq -r .data.attributes.guest_token)
  ```

# Adding a new version

Edit `versions.yaml` and append an entry with the version, commit hash, and the Jenkins build numbers for each architecture:

```yaml
versions:
  - version: "11.2.2"
    commit: "62159c9a2f"
    builds:
      linux-x86: 101
      linux-arm: 20
```

The release tarballs are pulled from S3 by the script — there is no manual download step.

# Image updates

Since the base OS regularly receives security patches, `update-multiplatform-images.sh` is run daily to ensure published images contain the latest fixes.

For every entry in `versions.yaml` the script:

1. Pulls the published image (both arches) and compares its layer hashes against a freshly-pulled `ubuntu:22.04`.
2. If the base has changed (or `FORCE_UPDATE_VERSION` matches the version), downloads the release tarballs from S3, extracts them into a per-version build context, and runs `docker buildx build --pull --platform linux/amd64,linux/arm64` against `docker/Dockerfile`.
3. If `PUSH_IMAGES` is set, the resulting multi-arch image is pushed to the registry.

Per-version build contexts under `build-context/<version>/` ensure each `buildx` invocation only sees the artifacts for the version being built. Downloaded tarballs are cached under `downloads/` and reused across runs; extracted contents are removed after a successful build.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `TOKEN` | yes | — | Ubuntu Pro token used to attach inside the build. |
| `PUSH_IMAGES` | no | (unset) | When set, the built image is pushed to the registry. Without this, multi-arch buildx output stays in the buildx cache and is not loaded into the local daemon. |
| `FORCE_UPDATE_VERSION` | no | (unset) | Substring match against `version`; forces a rebuild even if the base image hasn't changed. |

# Customizing the image

The Curity Identity Server is a Java-based product and can run in many docker setups.\
The default docker image runs as a low-privilege `10001` user account (`idsvr`).\
Customers can update this user account and apply their own image policy when required.

## Kubernetes non-root check

If you deploy with the Kubernetes `runAsNonRoot` security context, the image already satisfies it (UID `10001`):

```yaml
spec:
  securityContext:
    runAsNonRoot: true
  containers:
  - name: curity
    image: custom_idsvr_fips:latest
```

## Custom image based on the provided images

If you need to install extra tools, overlay this image. Operations that require root should switch user temporarily:

[//]: # (todo) update the repository
```dockerfile
FROM curity.azurecr.io/curity/idsvr-fips:11.2.2
USER root
RUN apt-get install -y curl
USER 10001:10000
```

Copying resources, such as plugins, can be done like so:

```dockerfile
COPY --chown=10001:10000 custom-plugin.jar /opt/idsvr/usr/share/plugins/custom-plugin-group/
```

# Contributing

Pull requests are welcome. To do so, just fork this repo, and submit a pull request.

# License

The software running in the Docker containers produced by the Dockerfiles maintained in this repository is licensed by Curity AB and others. The Docker-related files and resources maintained in this repository are licensed under the [Apache 2 license](LICENSE).

# More Information

Please visit [curity.io](https://curity.io/) for more information about the Curity Identity Server.

Copyright (C) 2026 Curity AB.
