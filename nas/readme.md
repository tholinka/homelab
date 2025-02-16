# NAS

The NAS runs Arch-Linux.

I wanted to have it join the talos cluster (primary for the observability, smartctl-exporter, node-exporter, etc), but I also want to use KubePrism, and that causes issues with non-Talos worker nodes.

So instead, it just runs a few docker-compose services.

Might eventually convert this to also be running as a single node kubernetes cluster...
