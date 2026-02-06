# DEPLOY_BUILDER_FOR_EIF.md

## 목적
`build_eif`를 사용할 때 **EIF(Enclave Image File) 빌드**는 GitHub hosted runner에서
불가능합니다. 이 문서는 **AWS 내 self-hosted runner**를 준비해
`runs-on: [self-hosted, nitro-eif]` 잡이 정상 동작하도록 설정하는 방법을 안내합니다.

> **현재 기본 배포는 One-shot deploy 워크플로**이며,
> **EIF 사전 빌드(`build_eif`) 잡은 제공하지 않습니다.**
> 필요 시 **커스텀 워크플로**에서 `build_eif`를 구성할 때 이 문서를 참고하세요.

> **참고(A 방식)**  
> 배포 단계에서 Router 주소를 고정해 EIF를 생성하는 방식(A 방식)을 사용할 경우,
> 별도의 self-hosted runner 없이 **Compute 호스트에서 EIF를 생성**합니다.
> 이 문서는 **사전 빌드 EIF(build_eif)**를 사용할 때에만 필요합니다.
> 사전 빌드 EIF는 **Router 주소가 이미 고정**되어 있어야 합니다.

### 적용 범위(커스텀 워크플로)
- `runs-on: [self-hosted, nitro-eif]`를 사용하는 `build_eif` 잡

## 사전 준비
- AWS 계정 및 VPC/서브넷
- S3 버킷(결과 EIF 업로드용)
  - Bucket policy should allow github-action and corresponding ec2 user.
- ECR 접근 권한(빌드 대상 이미지 pull)
- GitHub repo 관리자 권한(러너 등록 필요)
- GitHub Secrets에 AWS 인증 정보 등록
  - (권장) `AWS_ROLE_ARN` (OIDC)
  - (선택) `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (Access Key 사용 시)

> 현재 기본 워크플로는 `configure-aws-credentials`에서 **OIDC 기반 인증**을 사용합니다.
> 커스텀 워크플로에서도 OIDC 사용을 권장합니다.

## EC2 최소 사양 (EIF 빌드 기준)
- **인스턴스 타입**: Nitro Enclaves 지원 타입 중 **xlarge 이상**
  - 예: `c6a.xlarge` (Minimum vcpu: 4)
- **AMI**: Ubuntu 22.04 LTS
- **디스크**: gp3 30GiB 이상 (최소): **AI Hallucination Possible** (It may be lower than 30GiB.)
- **네트워크**: 아웃바운드 443 허용 (ECR/S3 접근)
- **IAM Role (선택)**: ECR read + S3 write 권한
  - runner 인스턴스에 Role을 부여하면 Access Key 없이도 동작할 수 있습니다.
  - 운영 환경에서는 최소 권한을 갖춘 전용 Role을 권장합니다.

> 빌드 시간이 길거나 이미지가 큰 경우 `xlarge` 이상으로 증설하는 것이 좋습니다.

## 설치 및 설정 절차

### 1) EC2 인스턴스 생성
1. Nitro Enclaves 지원 인스턴스 타입 선택
2. Ubuntu 22.04 AMI 선택
3. 보안 그룹에서 **아웃바운드 443 허용**
4. 필요 시 SSH 접속을 위한 인바운드 규칙 추가

### 2) 필수 패키지 설치 and Checking the environment
```bash
sudo apt-get update
sudo apt-get install -y docker.io awscli linux-modules-extra-aws build-essential
sudo reboot
```

After reboot (kernel updated)
```bash
sudo insmod /usr/lib/modules/6.8.0-1044-aws/kernel/drivers/virt/nitro_enclaves/nitro_enclaves.ko
lsmod | grep nitro
```
Check if ```nitro_enclaves``` is on.

```bash
sudo systemctl enable --now docker
sudo systemctl enable --now nitro-enclaves-allocator
sudo usermod -aG docker $(whoami)
```

### 3) Nitro Enclave Build & Install

This section is from https://github.com/aws/aws-nitro-enclaves-cli
Anyway, hey Amazon! what a messy deployment!!!

```bash
git clone https://github.com/aws/aws-nitro-enclaves-cli.git
cd aws-nitro-enclaves-cli
```
#### Edit bootstrap/nitro-cli-config (due to commit changes, line number mismatches!)
```
$ git diff bootstrap/nitro-cli-config
diff --git a/bootstrap/nitro-cli-config b/bootstrap/nitro-cli-config
index 35d424b..8099975 100755
--- a/bootstrap/nitro-cli-config
+++ b/bootstrap/nitro-cli-config
@@ -450,19 +450,6 @@ function driver_insert {
     local log_file="/var/log/$RES_DIR_NAME/nitro_enclaves.log"
     local loop_idx=0
-    # Remove an older driver if it is inserted.
-    if [ "$(lsmod | grep -cw $DRIVER_NAME)" -gt 0 ]; then
-        driver_remove
-    fi
-
-    print "Inserting the driver..."
-
-    # Insert the new driver.
-    sudo_run "insmod $DRIVER_NAME.ko" || fail "Failed to insert driver."
-
-    # Verify that the new driver has been inserted.
-    [ "$(lsmod | grep -cw $DRIVER_NAME)" -eq 1 ] || fail "The driver is not visible."
-
     print "Configuring the device file..."
     # Create the NE group if it doesn't already exist.
```

#### Edit bootstrap/env.sh (due to commit changes, line number mismatches!)
```
$ git diff bootstrap/env.sh
diff --git a/bootstrap/env.sh b/bootstrap/env.sh
index 1ebcabd..9df6331 100755
--- a/bootstrap/env.sh
+++ b/bootstrap/env.sh
@@ -9,8 +9,5 @@ then
     return -1
 fi
-lsmod | grep -q nitro_enclaves || \
-    sudo insmod ${NITRO_CLI_INSTALL_DIR}/lib/modules/extra/nitro_enclaves/nitro_enclaves.ko
-
 export PATH=${PATH}:${NITRO_CLI_INSTALL_DIR}/usr/bin/:${NITRO_CLI_INSTALL_DIR}/etc/profile.d/
 export NITRO_CLI_BLOBS=${NITRO_CLI_INSTALL_DIR}/usr/share/nitro_enclaves/blobs
```

### Edit Makefile (due to commit changes, line number mismatches!)
```
$ git diff Makefile
diff --git a/Makefile b/Makefile
index dff654c..76f3b1a 100644
--- a/Makefile
+++ b/Makefile
@@ -318,10 +318,7 @@ install-tools:
        $(CP) -r examples/${HOST_MACHINE}/* ${NITRO_CLI_INSTALL_DIR}${DATA_DIR}/nitro_enclaves/examples/
 .PHONY: install
-install: install-tools nitro_enclaves
-       $(MKDIR) -p ${NITRO_CLI_INSTALL_DIR}/lib/modules/$(uname -r)/extra/nitro_enclaves
-       $(INSTALL) -D -m 0755 drivers/virt/nitro_enclaves/nitro_enclaves.ko \
-               ${NITRO_CLI_INSTALL_DIR}/lib/modules/$(uname -r)/extra/nitro_enclaves/nitro_enclaves.ko
+install: install-tools
        $(INSTALL) -D -m 0644 bootstrap/env.sh ${NITRO_CLI_INSTALL_DIR}${ENV_SETUP_DIR}/nitro-cli-env.sh
        $(INSTALL) -D -m 0755 bootstrap/nitro-cli-config ${NITRO_CLI_INSTALL_DIR}${ENV_SETUP_DIR}/nitro-cli-config
        sed -i "2 a NITRO_CLI_INSTALL_DIR=$$(readlink -f ${NITRO_CLI_INSTALL_DIR})" \
```

#### configure and build

```
export NITRO_CLI_INSTALL_DIR=/
newgrp docker  ### docker often cannot recognize the group without this.
make nitro-cli
make vsock-proxy
```

#### install
```
sudo make NITRO_CLI_INSTALL_DIR=/ install
source /etc/profile.d/nitro-cli-env.sh
echo source /etc/profile.d/nitro-cli-env.sh >> ~/.bashrc
nitro-cli-config -i    ### you should still be in aws nitro-enclaves-cli directory.
cat /etc/nitro_enclaves/allocator.yaml    ### Edit memory size 512MB → 2048MB (for action runner)
sudo systemctl start nitro-enclaves-allocator.service
sudo systemctl enable nitro-enclaves-allocator.service
cd ..
```

#### Test

Infra test
```
docker --version
nitro-cli --version
sudo nitro-cli describe-enclaves
```

Hello world test
```
nitro-cli build-enclave --docker-dir /usr/share/nitro_enclaves/examples/hello --docker-uri hello:latest --output-file hello.eif
nitro-cli run-enclave --cpu-count 2 --memory 512 --enclave-cid 16 --eif-path hello.eif --debug-mode
```

You must kill hello.eif before proceed!
```
kill ****
```


### 5) GitHub self-hosted runner 설치/등록
1. GitHub → **Settings → Actions → Runners → New self-hosted runner**
2. 안내에 따라 runner 다운로드 및 설치
```
mkdir actions-runner && cd actions-runner
curl -o actions-runner-linux-x64-2.331.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.331.0/actions-runner-linux-x64-2.331.0.tar.gz
echo "5fcc01bd546ba5c3f1291c2803658ebd3cedb3836489eda3be357d41bfcf28a7  actions-runner-linux-x64-2.331.0.tar.gz" | shasum -a 256 -c
tar xzf ./actions-runner-linux-x64-2.331.0.tar.gz
```
3. During the configuration, you will get prompted. **라벨을 `nitro-eif`로 지정**
   - 워크플로는 `runs-on: [self-hosted, nitro-eif]`를 사용합니다.
```
./config.sh --url https://github.com/nnstreamer/hybrid --token *****************  # github will give you the token
```

4. Start Github runner!
```
./run.sh
```

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
