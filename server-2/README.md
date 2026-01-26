# server-2

This is the compute node of the PCC system.

## Version 0.001, the first prototype

This is the compute node directly created by the default configuration of
openpcc and confidentsecurity/confidentcompute.

This uses Ollama as the LLM runtime and bakes the default 1B model into the
image at build time for offline enclave use. No NVIDIA acceleration or other
optimizations are enabled in this prototype.

Further changes for optimization, flexibility, or rebasing on TAOS-D will be
done in later versions.
