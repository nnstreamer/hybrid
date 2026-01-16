 # Prototype-1 Architecture
 
 This prototype is a minimal, OpenPCC-based PCC system that favors reuse of the
 upstream OpenPCC reference services over custom code.
 
 ## Components
 
 ### Client (Ubuntu CLI)
 - Uses the OpenPCC test client to send a request to the system.
 - Source: `github.com/openpcc/openpcc/cmd/test-client`.
 
 ### Server-1 (OpenPCC relay/router gateway)
 - Runs OpenPCC in-memory services to simulate the gateway side:
   - `mem-auth` (config + auth) on 3000
   - `ohttp-relay` on 3100
   - `mem-gateway` on 3200
   - `mem-bank` on 3500
   - `mem-credithole` on 3501
   - `mem-router` on 3600
 - Image definition: `server-1/Dockerfile`
 
 ### Server-2 (OpenPCC compute node prototype)
 - Runs OpenPCC `mem-compute` with fake attestation enabled.
 - Listens on 3700 and registers to the router at `http://localhost:3600`.
 - Image definition: `server-2/Dockerfile`
 
 ## Request Flow
 
 1. Client fetches config from `mem-auth` (port 3000).
 2. Client sends an OHTTP request to the relay (port 3100).
 3. Relay forwards to gateway (port 3200).
 4. Gateway routes to router (port 3600) or bank (port 3500) based on host.
 5. Router forwards to compute node (server-2, port 3700).
 
 ## Prototype Notes
 
 - `mem-compute` uses `http://localhost:3600` for router registration. For a
   multi-host setup, server-2 supports optional port forwarding with
   `ROUTER_FORWARD_HOST` (see `server-2/entrypoint.sh`).
 - This is a prototype; production deployment should replace the in-memory
   services with production-grade components (e.g., ConfidentCompute).
 
 ## Upstream Reuse
 
 - OpenPCC version is pinned via Docker build arguments (default: `v0.0.80`).
