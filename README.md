# hybrid
Private Cloud Compute System, Serving NNStreamer Pipelines, LLMs, Agents. Yet Another Spin-Off! This is a server image creation &amp; deployment service, combining other open source packages.

This is a temporary project name. Suggest a better name!

## Objectives
- Provide a minimal OpenPCC-based prototype with two server roles.
- Reuse upstream OpenPCC components instead of re-implementing services.
- Offer a simple Ubuntu CLI client for smoke testing.
- Support CI build/pack and AWS deploy workflows.

## Architecture
See `ARCHITECTURE.md` for the prototype topology and ports.

## CI Build/Deploy
- `build-pack` builds Docker images and uploads artifacts.
- `deploy-aws` downloads artifacts and pushes to ECR.

Required GitHub secrets for deploy:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `AWS_ACCOUNT_ID`
- `ECR_REPOSITORY_SERVER1`
- `ECR_REPOSITORY_SERVER2`
