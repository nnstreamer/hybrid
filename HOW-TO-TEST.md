# HOW-TO-TEST.md

이 문서는 **oHTTP 포함** 경로로 `server-1/2/3/4` 전체를 통과하는
간단한 테스트를 수행하는 방법을 설명합니다.
테스트 클라이언트는 `/client/cli/fake_attestation`을 사용합니다.

---

## 1) 사전 조건 (공통)

- 테스트 대상 서버가 실행 중이어야 합니다.
  - fake_attestation은 **fake attestation** 경로이므로
    `enable_fake_attestation_for_server2=true` 환경을 전제로 합니다.
- 테스트를 실행하는 머신에서 필요한 포트에 접근 가능해야 합니다.
  - oHTTP 포함 시: `server-4(3100/tcp)`, `server-3(8080/tcp)`(시나리오 A에서만)
  - oHTTP 미사용 시: `server-1(3600/tcp)`
- oHTTP 시나리오에서는 **OHTTP_SEEDS_JSON** 값이 필요합니다.
  - 포맷은 `HOW-TO-DEPLOY.md`의 **6-2a** 섹션을 참고하세요.

---

## 2) 테스트 경로 요약 (oHTTP 전체 경로)

시나리오 A는 아래 경로를 통과합니다.

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

## 3) OHTTP_SEEDS_JSON 설정 방법

`OHTTP_SEEDS_JSON`은 **JSON 배열 문자열**이어야 합니다.
다음 방식 중 하나를 사용하세요.

### 3-1. 환경 변수로 직접 입력

```bash
export OHTTP_SEEDS_JSON='[{"key_id":"01","seed_hex":"...","active_from":"2026-01-30T00:00:00Z","active_until":"2026-07-30T00:00:00Z"}]'
```

### 3-2. 파일에서 읽어 넣기 (권장)

```bash
export OHTTP_SEEDS_JSON="$(jq -c . /path/to/ohttp_seeds.json)"
```

### 3-3. INI 파일에 넣기 (한 줄로)

```
ohttp_seeds_json=[{"key_id":"01","seed_hex":"...","active_from":"2026-01-30T00:00:00Z","active_until":"2026-07-30T00:00:00Z"}]
```

> 주의:
> - 파일 경로(`/path/to/...`)를 그대로 넣으면 JSON이 아니므로 실패합니다.
> - JSON에 `//` 주석이 있으면 파싱 실패합니다.
> - 줄바꿈 없는 **한 줄 JSON**이어야 합니다.

---

## 4) 필요한 값 수집 (시나리오 A)

### 4-1. server-3 URL

예시:
```
SERVER3_URL="http://<server3-public-ip>:8080"
```

### 4-2. relay URL (server-4)

예시:
```
RELAY_URL="http://<server4-public-ip>:3100"
```

### 4-3. OHTTP_SEEDS_JSON

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

## 5) server-3 동작 확인 (시나리오 A)

### 5-1. Health check

```bash
curl -s "${SERVER3_URL}/healthz"
```

정상 응답 예:
```json
{"status":"ok"}
```

### 5-2. Remote config 확인

```bash
curl -s "${SERVER3_URL}/api/config" | jq .
```

확인 포인트:
- `features.ohttp == true`
- `relay_urls`에 `RELAY_URL`이 포함되어 있는지
- `gateway_url` / `router_url` 값 존재 여부
- `ohttp_key_configs_bundle` / `ohttp_key_rotation_periods` 존재 여부

---

## 6) fake_attestation 실행 (시나리오 A: oHTTP 포함)

### 6-1. 환경 변수 설정

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

### 6-2. 실행

```bash
cd client/cli/fake-attestation
go run . -ohttp=enable
```

성공 시 응답 본문이 출력됩니다.

---

## 7) 성공 기준 (시나리오 A)

- `server-3 /healthz`가 200 응답
- `server-3 /api/config`에서 oHTTP 관련 값이 정상 출력
- `fake_attestation` 실행 결과가 2xx 응답이며 본문이 출력됨

---

## 8) 실패 시 점검 포인트 (시나리오 A)

- `RELAY_URL` 접근 불가:
  - server-4 보안그룹에서 `3100/tcp` 인바운드 허용 여부
- `server-3 /api/config`가 5xx:
  - server-3 config JSON 형식 확인
  - `ohttp_seeds` 형식/필수 필드(`key_id`, `seed_hex`, `active_from`, `active_until`)
- `fake_attestation`가 4xx/5xx:
  - `OHTTP_SEEDS_JSON`이 **server-1/server-3와 동일**한지 확인
  - `active_from/active_until` 기간이 현재 시간과 겹치는지 확인
  - server-2 (compute) 인스턴스가 정상 기동 중인지 확인

---

## 9) 시나리오 B: server-1 + server-2 + server-4 (auth 없이 oHTTP 테스트)

> 이 시나리오는 **server-3 없이** oHTTP 경로를 확인합니다.  
> fake_attestation은 내부 fake auth client를 사용하므로 가능하지만,
> 이는 **테스트 전용**입니다.

### 9-1. 준비

- `server-1`/`server-2`/`server-4`가 실행 중인지 확인
- `RELAY_URL`, `OHTTP_SEEDS_JSON` 준비
- `OHTTP_SEEDS_JSON`이 **server-1에서 사용 중인 seed와 동일**해야 합니다.

### 9-2. 실행

```bash
export RELAY_URL="http://<server4-public-ip>:3100"
export OHTTP_SEEDS_JSON='<seeds-json-here>'
cd client/cli/fake-attestation
go run . -ohttp=enable
```

### 9-3. 성공 기준

- `fake_attestation` 실행 결과가 2xx 응답이며 본문이 출력됨

---

## 10) 시나리오 C: server-1 + server-2 (auth/oHTTP 제외)

> 이 시나리오는 **router 직접 호출** 경로입니다.

### 10-1. 준비

- `server-1`/`server-2`가 실행 중인지 확인
- `ROUTER_URL` 준비 (port 3600)

### 10-2. 실행

```bash
export ROUTER_URL="http://<server1-public-ip>:3600"
cd client/cli/fake-attestation
go run . -ohttp=disable
```

### 10-3. 성공 기준

- `fake_attestation` 실행 결과가 2xx 응답이며 본문이 출력됨

