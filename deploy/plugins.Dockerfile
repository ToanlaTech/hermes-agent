# Tiny image carrying ONLY the custom plugin code from the `hermes-plugins`
# git submodule. Built separately from the main Hermes image so:
#   - the heavily-maintained upstream Dockerfile is never touched (no merge
#     conflicts when syncing NousResearch/hermes-agent),
#   - plugin changes rebuild in seconds instead of rebuilding all of Hermes,
#   - the plugin version is pinned per commit and rolls back independently.
#
# The StatefulSet's `plugin-sync` initContainer runs this image and copies
# /plugins-src onto the PVC at /opt/data/plugins.
FROM busybox:1.36
COPY hermes-plugins/ /plugins-src/
# Drop VCS / cache / runtime-data noise that must never ship in the image.
RUN rm -rf /plugins-src/.git \
    && find /plugins-src -name '__pycache__' -type d -prune -exec rm -rf {} + \
    && find /plugins-src -name '*.pyc' -delete
