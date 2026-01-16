# client

This provides Tizen/Android libraries for LLM serving via server-1.
This also provides sample client applications (or test apps).

## Prototype CLI Test
Run the OpenPCC test client against the local prototype:
- Start server-1 and server-2 containers.
- Run `./run-test.sh` from this directory.

Notes:
- Requires Go compatible with the OpenPCC module version.
- Target API URL is `http://localhost:3000` as defined by OpenPCC test client.
