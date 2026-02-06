# server-2

This is the compute node of the OpenPCC v0.002 stack.

## Overview

- Built from confidentsecurity/confidentcompute.
- Uses Ollama as the default LLM runtime and bakes the default 1B model at build time.
- Fake attestation build tags are available for local/dev; real attestation is expected for production.
- The one-shot deploy workflow runs this as a Nitro Enclave (EIF built at deploy time).
