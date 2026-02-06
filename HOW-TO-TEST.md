# HOW-TO-TEST.md

이 문서는 **oHTTP 포함** 경로로 `server-1/2/3/4` 전체를 통과하는
간단한 테스트를 수행하는 방법을 설명합니다.
테스트 클라이언트는 `/client/cli/fake_attestation`을 사용합니다.

---

## 1) 사전 조건

- one-shot deploy가 성공적으로 완료되어 있어야 합니다.
  - `enable_server3=true`
  - `enable_server4=true`
  - `enable_ohttp=true`
  - `enable_fake_attestation_for_server2=true` (기본값)
- 테스트를 실행하는 머신에서 다음 포트로 접근 가능해야 합니다.
  - `server-3` (auth): `8080/tcp`
  - `server-4` (relay): `3100/tcp`
- 배포에 사용한 **OHTTP_SEEDS_JSON** 값이 준비되어 있어야 합니다.
  - 포맷은 `HOW-TO-DEPLOY.md`의 **6-2a** 섹션을 참고하세요.

---

## 2) 테스트 경로 요약

이 테스트는 아래 경로를 통과합니다.

```
fake_attestation client
  -> server-4 (relay)
  -> server-1 (gateway)
  -> server-1 (router)
  -> server-2 (compute enclave)
```

또한 `server-3`는 `/api/config` 응답으로
oHTTP 키/릴레이 설정이 정상인지 확인합니다.

---

## 3) 필요한 값 수집

### 3-1. server-3 URL

예시:
```
SERVER3_URL="http://<server3-public-ip>:8080"
```

### 3-2. relay URL (server-4)

예시:
```
RELAY_URL="http://<server4-public-ip>:3100"
```

### 3-3. OHTTP_SEEDS_JSON

배포에 사용한 JSON을 그대로 사용합니다.

예시(형식):
```json
[
  {
    "key_id": "01",
    "seed_hex": "0123456789abcdef...64hex...",
    "active_from": "2026-01-30T00:00:00Z",
    "active_until": "2026-07-30T00:00:00Z"
  }
]
```

---

## 4) server-3 동작 확인

### 4-1. Health check

```bash
curl -s "${SERVER3_URL}/healthz"
```

정상 응답 예:
```json
{"status":"ok"}
```

### 4-2. Remote config 확인

```bash
curl -s "${SERVER3_URL}/api/config" | jq .
```

확인 포인트:
- `features.ohttp == true`
- `relay_urls`에 `RELAY_URL`이 포함되어 있는지
- `gateway_url` / `router_url` 값 존재 여부
- `ohttp_key_configs_bundle` / `ohttp_key_rotation_periods` 존재 여부

---

## 5) fake_attestation 실행 (oHTTP 포함)

### 5-1. 환경 변수 설정

```bash
export RELAY_URL="http://<server4-public-ip>:3100"
export OHTTP_SEEDS_JSON='<seeds-json-here>'
export MODEL_NAME="llama3.2:1b"
export PROMPT_TEXT="Hello from OpenPCC."
# 필요 시:
# export FAKE_ATTESTATION_SECRET="123456"
```

> `-ohttp` 옵션이 **필수**입니다.  
> `-ohttp=enable`로 지정해야 oHTTP 경로가 사용됩니다.

### 5-2. 실행

```bash
cd client/cli/fake-attestation
go run . -ohttp=enable
```

성공 시 응답 본문이 출력됩니다.

---

## 6) 성공 기준

- `server-3 /healthz`가 200 응답
- `server-3 /api/config`에서 oHTTP 관련 값이 정상 출력
- `fake_attestation` 실행 결과가 2xx 응답이며 본문이 출력됨

---

## 7) 실패 시 점검 포인트

- `RELAY_URL` 접근 불가:
  - server-4 보안그룹에서 `3100/tcp` 인바운드 허용 여부
- `server-3 /api/config`가 5xx:
  - server-3 config JSON 형식 확인
  - `ohttp_seeds` 형식/필수 필드(`key_id`, `seed_hex`, `active_from`, `active_until`)
- `fake_attestation`가 4xx/5xx:
  - `OHTTP_SEEDS_JSON`이 **server-1/server-3와 동일**한지 확인
  - `active_from/active_until` 기간이 현재 시간과 겹치는지 확인
  - server-2 (compute) 인스턴스가 정상 기동 중인지 확인

