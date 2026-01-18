# HOW TO DEPLOY (AWS Beginner Friendly)

이 문서는 GitHub Actions로 OpenPCC Prototype 1을 AWS에 배포하는 방법을 단계별로 설명합니다.
초보자가 따라할 수 있도록 최소 개념과 입력값을 정리했습니다.

---

## 0) 빠른 체크리스트

- [ ] AWS 계정 준비
- [ ] GitHub Actions Secrets에 AWS 키 저장
- [ ] ECR 리포지토리 생성
- [ ] VPC Subnet, Security Group 준비
- [ ] EC2 Instance Profile(역할) 준비
- [ ] AMI ID(예: Ubuntu 22.04) 결정
- [ ] GitHub Actions에서 Build/Deploy 워크플로 실행

---

## 1) GitHub Actions 인증 정보(Access Key) 준비

이 프로젝트의 워크플로는 **AWS Access Key** 방식으로 인증합니다.

### 1-1. IAM 사용자 생성

1. AWS 콘솔 → IAM → Users → Create user
2. Programmatic access 사용 가능하도록 Access Key 생성

### 1-2. 최소 권한 정책(개념)

배포에는 대략 다음 권한이 필요합니다:

- EC2 인스턴스 생성 (`ec2:RunInstances`, `ec2:CreateTags`)
- ECR 로그인/이미지 조회
- (선택) S3에서 EIF 다운로드
- 인스턴스에 역할을 부착하기 위한 `iam:PassRole`

### 1-3. GitHub Secrets 등록

GitHub 리포지토리 → Settings → Secrets and variables → Actions 에 아래를 추가:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

이 값들은 워크플로가 자동으로 사용합니다.

---

## 2) ECR 리포지토리 생성

이미지 빌드/푸시 및 배포를 위해 ECR이 필요합니다.

### 2-1. ECR 리포지토리 이름

스크립트 기본값은 아래 이름입니다:

- `openpcc-router`
- `openpcc-compute`
- `openpcc-client` (선택)

### 2-2. ECR 생성 방법

AWS 콘솔 → ECR → Create repository

---

## 3) 네트워크 준비 (VPC, Subnet, Security Group)

### 3-1. Subnet ID

배포할 VPC의 **퍼블릭 Subnet ID**가 필요합니다.

### 3-2. Security Group 예시

- Router(서버-1)
  - TCP 3600 (router)
  - TCP 3501 (credithole)
- Compute(서버-2)
  - TCP 8081 (router_com)
  - 가능하면 **Router Security Group에서만 접근 허용** 권장

---

## 4) EC2 Instance Profile(역할) 준비

EC2 인스턴스가 ECR 및 S3에 접근하려면 Instance Profile(역할)이 필요합니다.

### 4-1. IAM Role 생성

1. IAM → Roles → Create role
2. Use case: EC2
3. 권한 예시: ECR read + S3 read(옵션)

### 4-2. Instance Profile ARN 확인

Role 생성 후 ARN을 복사해 둡니다.

---

## 5) AMI 선택

이 시스템은 Ubuntu 22.04를 기준으로 구성되어 있습니다.

예시:

- Ubuntu 22.04 LTS AMI ID

**Compute Node(서버-2)** 는 Nitro Enclaves 지원 인스턴스 타입이 필요합니다.

---

## 6) 빌드/패킹 워크플로 실행 (선택)

GitHub Actions → `OpenPCC Proto 1 Build Pack` 워크플로를 실행합니다.

### 주요 입력값

- `component`: `all` / `server-1` / `server-2` / `client`
- `push`: `true`면 ECR로 푸시
- `build_eif`: `true`면 EIF 생성 시도
- `aws_region`: ECR 리전

> EIF를 미리 생성해 S3에 저장하려면 `build_eif=true` 후 EIF 파일을 S3에 업로드하세요.
> EIF 기본 출력 경로는 `artifacts/compute.eif`이며, 필요 시 `EIF_OUTPUT_DIR`로 변경할 수 있습니다.

---

## 7) 배포 워크플로 실행 (필수)

GitHub Actions → `OpenPCC Proto 1 Deploy` 워크플로 실행

> 배포 스크립트는 Nitro Enclave 실행을 전제로 합니다. Docker 기반 테스트는 로컬/CI 스모크 테스트 용도입니다.

### 7-1. 필수 입력값

- `aws_region`
- `subnet_id`
- `security_group_id`
- `instance_profile_arn`
- `ami_id` (또는 router/compute 전용 AMI)

### 7-2. 선택 입력값

- `key_name` (EC2 SSH 키, 필요 시)
- `compute_eif_s3_uri` (S3의 EIF 경로)
- 인스턴스 타입 변경

---

## 8) 배포 후 확인

1. EC2 콘솔에서 인스턴스 생성 확인
2. Router 인스턴스에서 포트 3600 응답 확인
3. 필요 시 client smoke test로 상태 점검

예시(로컬에서 실행):

- `ROUTER_URL=http://<router-ip>:3600 ./client/smoke_test.sh`

---

## 9) 자주 묻는 질문(초보자용)

### Q1. Access Key를 코드에 넣어야 하나요?
아니요. **GitHub Secrets에 저장하면 워크플로가 자동으로 사용**합니다.

### Q2. 왜 Instance Profile이 필요한가요?
EC2 내부에서 **ECR pull / S3 다운로드**가 필요하기 때문입니다.

### Q3. EIF는 꼭 필요하나요?
Nitro Enclaves를 쓰는 경우 EIF가 필요합니다.  
즉시 테스트만 한다면 로컬/CI에서 Docker 기반으로 실행할 수 있습니다(개발용).

---

## 10) 요약

1. AWS 키를 GitHub Secrets에 등록
2. ECR/네트워크/AMI/Instance Profile 준비
3. Build/Deploy 워크플로 실행

여기까지 완료하면 GitHub Actions만으로 배포가 가능합니다.

---

## 11) 로컬 system_test.sh 실행 시 주의사항

이 섹션은 로컬 통합 테스트(`system_test.sh`) 실행 중 겪는 문제를 예방하기 위한 안내입니다.

### 11-1. sudo 실행 권장

Docker 데몬 권한 문제를 피하려면 다음 방식으로 실행합니다.

- `sudo -E ./system_test.sh`

빌드/실행이 서로 다른 Docker 데몬을 사용하면 이미지가 보이지 않는 문제가 발생할 수 있습니다.

### 11-2. 고정 컨테이너/포트 충돌

스크립트는 고정된 컨테이너 이름과 호스트 포트를 사용합니다.

- 컨테이너: `openpcc-tpm-sim`, `openpcc-ollama`, `openpcc-router`, `openpcc-compute`
- 포트: 2321, 2322, 11434, 3600, 8081

이미 동일한 컨테이너/포트가 사용 중이면 충돌이 발생할 수 있습니다.

### 11-3. Transparency policy 에러

로컬 클라이언트 코드에서 투명성 정책이 없으면 다음 에러가 날 수 있습니다.

- `transparency identity policy source is 'configured' but no policy was provided`

테스트 클라이언트 코드를 수정할 경우에는 `LocalDevIdentityPolicy`를 설정하세요.
