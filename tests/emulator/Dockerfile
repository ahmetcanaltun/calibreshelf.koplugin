# Headless KOReader (official Linux arm64 build) for exercising CalibreShelf UI.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11vnc xdotool imagemagick libsdl2-2.0-0 xz-utils ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*
ARG KO_TARBALL
COPY ${KO_TARBALL} /tmp/ko.tar.xz
RUN tar -xJf /tmp/ko.tar.xz -C /opt && rm /tmp/ko.tar.xz
COPY in-container.sh /in-container.sh
CMD ["/in-container.sh"]
