# HOW TO DEPLOY (AWS Beginner Friendly)

이 문서는 GitHub Actions로 OpenPCC v0.002를 AWS에 배포하는 방법을 단계별로 설명합니다.
초보자가 따라할 수 있도록 최소 개념과 입력값을 정리했습니다.

---

## 0) 빠른 체크리스트

- [ ] AWS 계정 준비
- [ ] GitHub Actions Secrets에 AWS_ROLE_ARN 저장
- [ ] 공개 레지스트리(ECR Public 등) 준비
- [ ] VPC Subnet, Security Group 준비 (router/compute 분리 권장)
- [ ] EC2 Instance Profile(역할) 준비
- [ ] AMI ID(예: Ubuntu 22.04) 결정
- [ ] GitHub Actions에서 One-shot deploy 워크플로 실행

---

## 1) GitHub Actions 인증 정보(OIDC Role) 준비

이 프로젝트의 워크플로는 **GitHub Actions OIDC로 AWS 역할을 가정**합니다.  
Access Key는 사용하지 않습니다.

### 1-1. IAM OIDC Provider 및 Role 생성

1. IAM → Identity providers → `token.actions.githubusercontent.com` 등록
2. IAM → Roles → Create role → **Web identity**
   - Provider: `token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`
   - (권장) Subject 제한: `repo:nnstreamer/hybrid:ref:refs/heads/*`

### 1-2. 최소 권한 정책(개념)

배포에는 대략 다음 권한이 필요합니다:

- EC2 인스턴스 생성 (`ec2:RunInstances`, `ec2:CreateTags`)
- 공개 레지스트리(ECR Public 등) 푸시/조회 권한
  - 예: `ecr-public:GetAuthorizationToken`, `ecr-public:CreateRepository`,
    `ecr-public:DescribeRepositories`, `ecr-public:BatchCheckLayerAvailability`,
    `ecr-public:InitiateLayerUpload`, `ecr-public:UploadLayerPart`,
    `ecr-public:CompleteLayerUpload`, `ecr-public:PutImage`
- **필수**: `sts:GetServiceBearerToken` (ECR Public 로그인/푸시용)
- 간단히는 `AmazonElasticContainerRegistryPublicFullAccess` 사용 가능
- Instance Profile을 부착할 때의 `iam:PassRole`

### 1-3. AWS_ROLE_ARN 확인 및 GitHub Secrets 등록

AWS Console:
- IAM → Roles → (GitHub Actions용 Role 선택) → **ARN**

CLI:
```bash
aws iam get-role --role-name <ROLE_NAME> --query Role.Arn --output text
```

GitHub 리포지토리 → Settings → Secrets and variables → Actions 에 아래를 추가:

- `AWS_ROLE_ARN`

이 값들은 워크플로가 자동으로 사용합니다.

---

## 2) 공개 레지스트리 준비 (ECR Public 권장)

이미지 빌드/푸시 및 배포를 위해 **로그인 없이 pull 가능한 공개 레지스트리**가 필요합니다.  
현재 워크플로는 **public ECR(public.ecr.aws/*)**만 허용합니다.

### 2-1. ECR 리포지토리 이름

스크립트 기본값은 아래 이름입니다:

- `openpcc-router`
- `openpcc-compute`
- `openpcc-client` (선택)

### 2-2. ECR Public 생성 방법

AWS 콘솔 → ECR → Create repository

---

## 3) 네트워크 준비 (VPC, Subnet, Security Group)

### 3-1. Subnet ID

배포할 VPC의 **퍼블릭 Subnet ID**가 필요합니다.

### 3-2. AWS Security Group 설정

가능하면 **server-1/2/3/4를 분리된 Security Group**으로 구성하는 것을 권장합니다.

#### server-1 (Router + Gateway)

- 인바운드
  - TCP 3600 (router)
  - TCP 3200 (gateway)
  - TCP 3501 (credithole)
- 권장 접근 제어
  - 3600은 server-2 SG에서만 허용
  - 3200은 server-4 SG에서만 허용 (oHTTP relay 사용 시)

#### server-2 (Compute)

- 인바운드
  - TCP 8081 (router_com)
- 권장 접근 제어
  - **server-1 SG에서만 접근 허용** 권장

#### server-3 (Auth)

- 인바운드
  - TCP 8080 (`/api/config`, `/healthz`)
- 권장 접근 제어
  - 운영 환경에 맞는 클라이언트/내부 네트워크만 허용

#### server-4 (Relay)

- 인바운드
  - TCP 3100 (oHTTP relay)
- 권장 접근 제어
  - 클라이언트 접근 필요 범위에 맞게 제한
  - **server-1 gateway(3200)** 으로의 아웃바운드가 가능해야 함

---

## 4) EC2 Instance Profile(역할) 준비 (필수)

모든 서버에 **Instance Profile을 부착**하도록 배포 스크립트가 고정되어 있습니다.  
따라서 Instance Profile은 **필수 입력값**입니다.

### 4-1. IAM Role 생성

1. IAM → Roles → Create role
2. Use case: EC2
3. 권한 예시: ECR read + S3 read(옵션)
   - `AmazonEC2ContainerRegistryReadOnly`
   - `AmazonS3ReadOnlyAccess` (EIF를 S3에서 내려받을 경우)
   - 가능하면 S3는 **특정 버킷/경로만 허용**하는 커스텀 정책으로 최소권한 적용 권장

### 4-2. Instance Profile ARN 확인

Role 생성 후 동일 이름의 **Instance Profile**이 자동 생성됩니다.
아래 경로에서 **Instance Profile ARN**을 복사해 두세요.

- IAM → Roles → (방금 만든 Role 선택) → Summary → **Instance profile ARN**

> 주의: **Role ARN과 Instance Profile ARN은 다릅니다.**  
> 배포 입력값에는 **Instance Profile ARN**을 사용해야 합니다.

CLI로 확인하려면:
```bash
aws iam list-instance-profiles-for-role --role-name <ROLE_NAME>
```
출력의 `Arn` 값이 Instance Profile ARN입니다.

---

## 5) AMI 선택

이 시스템은 Ubuntu 22.04를 기준으로 구성되어 있습니다.

예시:

- Ubuntu 22.04 LTS AMI ID

**Compute Node(서버-2)** 는 Nitro Enclaves 지원 인스턴스 타입이 필요합니다.

---

## 6) One-shot deploy 워크플로 실행 (필수)

GitHub Actions → `OpenPCC v0.002 One-shot Deploy` 워크플로를 실행합니다.  
이 워크플로는 **build/pack/deploy를 한 번에** 수행하며,  
`server-1 → server-4 → server-3 → server-2` 순서로 **순차 배포**를 진행합니다.

> 배포 스크립트는 Nitro Enclave 실행을 전제로 합니다. Docker 기반 테스트는 로컬/CI 스모크 테스트 용도입니다.

### 6-1. 필수 입력값 (직접 입력 또는 저장값 필요)

- `aws_region`
- `subnet_id`
- `router_security_group_id`
- `compute_security_group_id`
- `ami_id` (공통 AMI 또는 server별 AMI 기반)
- `image_registry` (public.ecr.aws/alias)
- `auth_security_group_id` (enable_server3=true일 때)
- `relay_security_group_id` (server-4 배포 스크립트를 사용할 때)

### 6-2. 선택 입력값

- `key_name` (EC2 SSH 키, 필요 시)
- `instance_profile_arn` (public ECR + OHTTP_SEEDS_JSON 직접 입력이면 생략 가능)
- `enable_server3` (server-3 빌드/배포 활성화)
- `enable_server4` (server-4 빌드/배포 활성화)
- `enable_server3_ohttp_advertise` (server-3 oHTTP config 광고)
- `enable_real_attestation_for_client` (client용 real attestation 정책 활성화)
- `enable_fake_attestation_for_server2` (server-2 fake attestation 빌드)
- `enable_compute_monitor` (server-2 모니터 설치)
- `compute_instance_type`, `edge_instance_type`
- `enclave_cpu_count`, `enclave_memory_mib`, `enclave_cid`
- `OPENPCC_RELAY_URLS_JSON` (enable_server3_ohttp_advertise=true 이면서 server-4를 배포하지 않을 때 필요)

> `enable_real_attestation_for_client=true`와 `enable_fake_attestation_for_server2=true`는 동시에 사용할 수 없습니다.
>
> 배포 스크립트는 **인스턴스 내부에서 ECR 로그인/S3 다운로드를 수행하지 않습니다.**  
> EIF는 Compute 인스턴스에서 **로컬로 생성**됩니다.

### 6-2a. OHTTP seed 설정 가이드 (v0.002 준비)

`one-shot deploy`는 oHTTP seed를 구성하기 위해 `OHTTP_SEEDS_JSON`을 읽습니다.  
`OHTTP_SEEDS_SECRET_REF`는 `deploy_server1.sh`가 **JSON을 조회해 주입할 때만** 사용됩니다
(gateway 자체는 `OHTTP_SEEDS_JSON`만 읽습니다).

**필수(One-shot deploy에서 enable_server3_ohttp_advertise=true): OHTTP_SEEDS_JSON 직접 입력**
- GitHub Secrets: `OPENPCC_OHTTP_SEEDS_JSON` (권장)
- 또는 Repository Variables: `OPENPCC_OHTTP_SEEDS_JSON`

예시(JSON 배열):
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

**참조 방식(OHTTP_SEEDS_SECRET_REF, 선택)**
- Repository Variable: `OPENPCC_OHTTP_SEEDS_SECRET_REF`

#### A) AWS Secrets Manager 사용

1) seed 데이터 준비(예: `ohttp_seeds.json`)
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

seed 생성 예시:
```bash
openssl rand -hex 32
```

2) Secrets Manager에 저장
```bash
aws secretsmanager create-secret \
  --name openpcc-ohttp-seeds \
  --secret-string file://ohttp_seeds.json
```

3) 출력된 ARN을 `OHTTP_SEEDS_SECRET_REF`로 설정
- `OPENPCC_OHTTP_SEEDS_SECRET_REF` Repository Variable에 입력

4) 인스턴스 프로파일 권한
- `secretsmanager:GetSecretValue` 권한을 해당 ARN에 부여
- `OHTTP_SEEDS_SECRET_REF`를 사용할 경우 `INSTANCE_PROFILE_ARN`이 필요합니다.

#### B) 다른 비밀 저장소 사용(예: SSM Parameter Store, Vault, S3 등)

1) 위와 동일한 JSON 포맷으로 저장
2) 참조 문자열을 `OHTTP_SEEDS_SECRET_REF`로 설정  
   - 예: `ssm:/openpcc/ohttp-seeds`, `vault://secret/openpcc/ohttp`, `s3://bucket/path/ohttp_seeds.json`
3) 해당 저장소에 접근 가능한 IAM/크레덴셜을 인스턴스에 부여

> 주의: `deploy_server1.sh`는 일부 저장소(AWS Secrets Manager/SSM)만 조회합니다.  
> `server-1` gateway 자체는 **OHTTP_SEEDS_JSON만** 읽습니다.

### 6-3. 개발용 TPM 시뮬레이터/프록시 구성

- 개발/로컬 테스트는 **TPM Simulator(mssim)** 를 사용합니다.
- 배포 스크립트는 Compute 호스트에 다음 **systemd 서비스**를 구성합니다:
  - `openpcc-tpm-sim`: TPM Simulator 실행
  - `openpcc-vsock-router`, `openpcc-vsock-tpm-*`: Enclave → Router/TPM 접근용 VSOCK 프록시
  - `openpcc-enclave-health-proxy`: Router → Enclave(8081) 헬스체크 프록시
- **운영 환경에서는 TPM Simulator를 제거**하고 **Nitro Enclave Attestation(NSM 기반)**으로 교체해야 합니다.
- `enclave_cid`는 **VSOCK 주소 식별자**이며, 호스트가 Enclave로 연결할 때 사용합니다.
  - 기본값(16)으로 동작하도록 구성되어 있으며, 변경 시 **호스트/Enclave 프록시가 동일 값**을 사용해야 합니다.
- TPM 시뮬레이터 포트는 기본적으로 **2321/2322**를 사용하며, 배포 스크립트는 platform 포트를 **cmd 포트 + 1**로 보정합니다.

### 6-4. 입력값 기본값 설정 (Repository Variables)

One-shot deploy는 **입력값이 비어 있으면 Repository Variables 값을 사용**합니다.  
**자동 저장 기능은 제공하지 않습니다.**

Variables 위치: GitHub 리포지토리 → Settings → Secrets and variables → Actions → Variables

**주요 변수 예시(기본값 용도)**
- `OPENPCC_AWS_REGION`
- `OPENPCC_SUBNET_ID`
- `OPENPCC_ROUTER_SECURITY_GROUP_ID`
- `OPENPCC_AUTH_SECURITY_GROUP_ID`
- `OPENPCC_COMPUTE_SECURITY_GROUP_ID`
- `OPENPCC_RELAY_SECURITY_GROUP_ID`
- `OPENPCC_INSTANCE_PROFILE_ARN`
- `OPENPCC_IMAGE_REGISTRY`
- `OPENPCC_KEY_NAME`
- `OPENPCC_AMI_ID`
- `OPENPCC_ENCLAVE_CPU_COUNT`
- `OPENPCC_ENCLAVE_MEMORY_MIB`
- `OPENPCC_ENCLAVE_CID`

> 이 값들은 **Secrets가 아니라 Variables**에 저장됩니다.  
> 민감한 값은 저장하지 않는 것을 권장합니다.

### 6-5. Known Issues (PoC)

- 현재 배포는 **server-1의 private IP를 기준**으로 router/gateway 주소를 구성합니다.
  - 모든 서버가 **동일 Subnet에 있는 PoC 환경**을 전제로 동작합니다.
  - 다른 배포 방식(예: 멀티 VPC, 퍼블릭 DNS/ALB, 교차 서브넷)에서는
    주소 해석 문제가 발생할 수 있습니다.
- **Prebuilt EIF 사용 시 router 주소 bake-in 문제**
  - 사전 빌드 EIF는 **router 주소가 이미 고정**되어 있어야 정상 동작합니다.
  - one-shot deploy처럼 **router IP가 배포 후 결정되는 흐름**에서는
    prebuilt EIF 사용을 권장하지 않습니다.

---

## 7) 배포 후 확인

1. EC2 콘솔에서 인스턴스 생성 확인
2. Router 인스턴스에서 포트 3600 응답 확인
3. 필요 시 client smoke test로 상태 점검

예시(로컬에서 실행):

- `ROUTER_URL=http://<router-ip>:3600 ./client/smoke_test.sh`

---

## 8) 자주 묻는 질문(초보자용)

### Q1. Access Key를 코드에 넣어야 하나요?
아니요. **GitHub Secrets에 `AWS_ROLE_ARN`을 등록하면** 워크플로가 자동으로 사용합니다.

### Q2. 왜 Instance Profile이 필요한가요?
다음 조건에서는 필요합니다.
- `OHTTP_SEEDS_SECRET_REF`로 seed를 조회할 때 (server-1에서 AWS API 호출)
- public ECR이 아닌 레지스트리를 사용할 때

public ECR 사용 + `OHTTP_SEEDS_JSON` 직접 입력이라면 **생략 가능**합니다.

### Q3. EIF는 꼭 필요하나요?
Nitro Enclaves를 쓰는 경우 EIF가 필요합니다.  
즉시 테스트만 한다면 로컬/CI에서 Docker 기반으로 실행할 수 있습니다(개발용).

---

## 9) 요약

1. AWS_ROLE_ARN을 GitHub Secrets에 등록
2. 공개 레지스트리/네트워크/AMI 준비 (필요 시 Instance Profile)
3. One-shot deploy 워크플로 실행

여기까지 완료하면 GitHub Actions만으로 배포가 가능합니다.

---

## 10) 로컬 system_test.sh 실행 시 주의사항

이 섹션은 로컬 통합 테스트(`system_test.sh`) 실행 중 겪는 문제를 예방하기 위한 안내입니다.

### 10-1. sudo 실행 권장

Docker 데몬 권한 문제를 피하려면 다음 방식으로 실행합니다.

- `sudo -E ./system_test.sh`

빌드/실행이 서로 다른 Docker 데몬을 사용하면 이미지가 보이지 않는 문제가 발생할 수 있습니다.

### 10-2. 고정 컨테이너/포트 충돌

스크립트는 고정된 컨테이너 이름과 호스트 포트를 사용합니다.

- 컨테이너: `openpcc-tpm-sim`, `openpcc-ollama`, `openpcc-router`, `openpcc-compute`
- 포트: 2321, 2322, 11434, 3600, 8081

이미 동일한 컨테이너/포트가 사용 중이면 충돌이 발생할 수 있습니다.

### 10-3. Transparency policy 에러

로컬 클라이언트 코드에서 투명성 정책이 없으면 다음 에러가 날 수 있습니다.

- `transparency identity policy source is 'configured' but no policy was provided`

테스트 클라이언트 코드를 수정할 경우에는 `LocalDevIdentityPolicy`를 설정하세요.
