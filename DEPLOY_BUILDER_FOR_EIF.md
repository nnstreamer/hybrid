# DEPLOY_BUILDER_FOR_EIF.md

## 목적
`build_eif`를 사용할 때 **EIF(Enclave Image File) 빌드**는 GitHub hosted runner에서
불가능합니다. 이 문서는 **AWS 내 self-hosted runner**를 준비해
`runs-on: [self-hosted, nitro-eif]` 잡이 정상 동작하도록 설정하는 방법을 안내합니다.

> **참고(A 방식)**  
> 배포 단계에서 Router 주소를 고정해 EIF를 생성하는 방식(A 방식)을 사용할 경우,
> 별도의 self-hosted runner 없이 **Compute 호스트에서 EIF를 생성**합니다.
> 이 문서는 **사전 빌드 EIF(build_eif)**를 사용할 때에만 필요합니다.
> 사전 빌드 EIF는 **Router 주소가 이미 고정**되어 있어야 합니다.

### 대상 워크플로
- `.github/workflows/deploy.yml` → `build-eif` job
- `.github/workflows/build-pack.yml` → `build-eif` job

## 사전 준비
- AWS 계정 및 VPC/서브넷
- S3 버킷(결과 EIF 업로드용)
- ECR 접근 권한(빌드 대상 이미지 pull)
- GitHub repo 관리자 권한(러너 등록 필요)
- GitHub Secrets에 AWS 자격증명 등록
  - `AWS_ACCESS_KEY_ID`
  - `AWS_SECRET_ACCESS_KEY`

> 이 레포의 워크플로는 `configure-aws-credentials`에서 **Access Key 기반 인증**을 사용합니다.
> IAM Role 기반(OIDC)으로 바꾸려면 워크플로 수정이 필요합니다.

## EC2 최소 사양 (EIF 빌드 기준)
- **인스턴스 타입**: Nitro Enclaves 지원 타입 중 **large 이상**
  - 예: `c6a.large` (2 vCPU, 4GiB), `c5.large`, `m6a.large` 등
- **AMI**: Ubuntu 22.04 LTS
- **디스크**: gp3 30GiB 이상 (최소)
- **네트워크**: 아웃바운드 443 허용 (ECR/S3 접근)
- **IAM Role (선택)**: ECR read + S3 write 권한
  - 워크플로는 Access Key를 사용하므로 필수는 아니지만,
    운영 환경에서는 최소 권한을 갖춘 전용 Role을 권장합니다.

> 빌드 시간이 길거나 이미지가 큰 경우 `xlarge` 이상으로 증설하는 것이 좋습니다.

## 설치 및 설정 절차

### 1) EC2 인스턴스 생성
1. Nitro Enclaves 지원 인스턴스 타입 선택
2. Ubuntu 22.04 AMI 선택
3. 보안 그룹에서 **아웃바운드 443 허용**
4. 필요 시 SSH 접속을 위한 인바운드 규칙 추가

### 2) 필수 패키지 설치
```bash
sudo apt-get update
sudo apt-get install -y docker.io awscli aws-nitro-enclaves-cli linux-modules-extra-aws
sudo systemctl enable --now docker
sudo systemctl enable --now nitro-enclaves-allocator
```

### 3) Nitro Enclaves 리소스 설정
`/etc/nitro_enclaves/allocator.yaml` 설정을 확인하고 리소스를 할당합니다.

예시:
```yaml
memory_mib: 2048
cpu_count: 2
```

설정 변경 후 allocator 재시작:
```bash
sudo systemctl restart nitro-enclaves-allocator
```

### 4) GitHub self-hosted runner 설치/등록
1. GitHub → **Settings → Actions → Runners → New self-hosted runner**
2. 안내에 따라 runner 다운로드 및 설치
3. **라벨을 `nitro-eif`로 지정**
   - 워크플로는 `runs-on: [self-hosted, nitro-eif]`를 사용합니다.

### 5) 동작 확인
```bash
docker --version
nitro-cli --version
sudo nitro-cli describe-enclaves
```
`describe-enclaves`가 정상 응답하면 Nitro CLI가 정상 동작 중입니다.

## 보안 권장사항
- **전용 인스턴스**로 격리 운영
- 최소 권한 IAM 정책 부여
- GitHub Secrets 접근 가능성을 고려해 접근 통제 강화

## 자주 발생하는 문제

### `nitro-cli build-enclave` 실패
- Nitro Enclaves 미지원 인스턴스인지 확인
- `linux-modules-extra-aws` 설치 여부 확인
- allocator 활성화/재시작 확인

### ECR pull 실패
- 네트워크 아웃바운드 443 허용 확인
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` 등록 확인

---
필요 시 이 문서를 기반으로 CI용 전용 AMI를 만들어 재사용하는 것도 권장합니다.
