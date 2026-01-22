# OpenPCC에서 프라이버시가 보존되는 방식 (Prototype 1)

이 문서는 본 레포지토리의 설계 문서와 설정을 기준으로, 클라이언트 쿼리/응답이
어떻게 보호되는지 요약합니다.

## 범위 및 근거

이 레포에서 확인한 근거:
- ARCHITECTURE.md (주요 설계 설명)
- server-2/config/compute_boot.yaml
- server-2/config/router_com.yaml
- HOW-TO-DEPLOY.md
- system_test.sh (로컬 테스트 설정)

중요한 범위 참고:
- 이 레포에는 실제 클라이언트 구현이 포함되어 있지 않습니다.
  아래 내용은 ARCHITECTURE.md 및 upstream OpenPCC 설계를 기준으로 한 설명입니다.

## 용어 요약

- REK: Compute enclave에서 생성되는 Request Encryption Key
- DEK: 클라이언트가 요청/세션 단위로 생성하는 Data Encryption Key
- HPKE: REK로 DEK를 감싸는(암호화하는) 공개키 기반 암호 방식
- BHTTP: 요청 페이로드 인코딩에 사용하는 Binary HTTP
- Attestation: compute node 신뢰성 검증 절차
- TPM: 증명과 키 관리를 위한 보안 모듈
- Nitro Enclave: 격리된 추론 실행 환경

## 프라이버시 보존의 핵심 흐름

1) 클라이언트는 Router로부터 ComputeNode의 증명 번들(TPM quote, PCR)을 수신한다.
2) 클라이언트는 증명(Attestation)을 검증한다.
3) 클라이언트가 쿼리를 암호화한다.
   - DEK 생성
   - REK로 DEK를 HPKE로 암호화
   - 프롬프트를 BHTTP로 직렬화하고 DEK로 암호화
4) Router는 복호화 없이 암호화된 요청을 전달한다.
5) Compute enclave가 TPM/REK로 DEK를 복호화하고, 프롬프트를 복호화해 추론한다.

응답 보호에 대한 참고:
- 이 레포 문서에는 응답 암호화 포맷이 명시되어 있지 않습니다.
  따라서 응답 보호는 upstream OpenPCC/ConfidentCompute 구현 확인이 필요합니다.

## 다이어그램: 암호화/복호화/전송 흐름

```mermaid
sequenceDiagram
  autonumber
  participant Client
  participant Router as Server-1 (Router)
  participant TPM
  participant Enclave as Server-2 (Compute Enclave)

  Router->>Client: 증명 번들(TPM quote + PCRs)
  Client->>Client: Attestation 검증

  Enclave->>TPM: REK 생성/보관
  Client->>Client: DEK 생성 (요청/세션 단위)
  Client->>Client: REK로 DEK HPKE 암호화
  Client->>Client: 프롬프트 BHTTP 직렬화
  Client->>Client: DEK로 프롬프트 암호화

  Client->>Router: 암호화 요청 (DEK 래핑 + ciphertext)
  Router->>Enclave: 암호화 요청 전달 (복호화 없음)

  Enclave->>TPM: REK로 DEK 복호화
  Enclave->>Enclave: DEK로 프롬프트 복호화
  Enclave->>Enclave: Enclave 내부에서 추론 수행

  opt 응답 보호 (구현에 따라 상이)
    Enclave-->>Router: 암호화 응답 (예: DEK 사용)
    Router-->>Client: 응답 전달 (복호화 없음)
  end
```

## 설계 문서 기반 보안 속성

- 전송 구간 기밀성: Router는 DEK가 없고 복호화를 하지 않으므로 내용을 볼 수 없다.
- Compute 구간 기밀성: 복호화는 enclave 내부에서 TPM 키를 통해 수행된다.
- 증명 기반 신뢰: 클라이언트가 TPM quote/PCR을 검증한 후 요청을 전송한다.
- 하드닝: SELinux, dm-verity(읽기 전용 FS), SSH 차단 등을 적용하도록 설계됨.
- 네트워크 분리 권장: Compute는 Router 보안 그룹에서만 접근하도록 권장됨.

## 개발용 설정 주의

- 로컬 테스트에서는 TPM 시뮬레이터 및 fake attestation secret을 사용할 수 있다.
  (compute_boot.yaml, system_test.sh) 운영 환경에서는 사용 금지.

## 확인 필요 사항

- 응답 암호화 포맷/키 사용 방식은 이 레포에 명시되어 있지 않으므로,
  upstream OpenPCC/ConfidentCompute 구현 확인 후 문서 보강이 필요하다.
