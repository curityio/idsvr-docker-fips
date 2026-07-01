#
# Copyright (C) 2026 Curity AB. All rights reserved.
#
# The contents of this file are the property of Curity AB.
# You may not copy or use this file, in either source code
# or executable form, except in compliance with terms
# set by Curity AB.
#
# For further information, please contact Curity AB.
#

FROM ubuntu:22.04

ARG VERSION
ARG COMMIT
ARG TARGETARCH

RUN --mount=type=secret,id=pro-attach-config-${TARGETARCH} \
    apt-get update && \
    apt-get install -y --no-install-recommends ubuntu-advantage-tools ca-certificates autoconf && \
    pro attach --attach-config /run/secrets/pro-attach-config-${TARGETARCH} && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y libssl3 libssl-dev && \
    { dpkg-query -W libssl3 | grep -q '+Fips' \
        || { echo "ERROR: installed libssl3 is not an Ubuntu Pro FIPS (+Fips) build ($(dpkg-query -W libssl3)) — pro attach/fips-updates likely failed" >&2; exit 1; }; } && \
    pro detach --assume-yes && \
    apt-get purge -y ubuntu-advantage-tools && \
    rm -rf /var/lib/ubuntu-advantage /etc/ubuntu-advantage && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN --mount=type=bind,source=enforce-fips-openssl.sh,target=/tmp/enforce-fips-openssl.sh \
    bash /tmp/enforce-fips-openssl.sh

RUN groupadd --system --gid 10000 idsvr && useradd --system --no-create-home --uid 10001 --gid 10000 idsvr

ENV IDSVR_HOME="/opt/idsvr"
ENV JAVA_HOME="$IDSVR_HOME/lib/java/jre"
ENV PATH="$IDSVR_HOME/bin:$JAVA_HOME/bin:$PATH"
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0"
WORKDIR $IDSVR_HOME


COPY --from=downloads --chown=10001:10000 idsvr-${VERSION}-${COMMIT}-${TARGETARCH}/idsvr /opt/idsvr
COPY --chown=10001:10000 first-run /opt/idsvr/etc/first-run

USER 10001:10000

CMD ["idsvr", "--fips-mode"]
