# The objective

For better understandings for developers and auditors.
For proper code generations for coding agents (cursor and antigravity).

# Overall Architecture

The followings are the basic components.
- TAOS-D
- server-1
- server-2
- server-3-auth (not included in this version)
- client
- .github/workflows

TAOS-D is a common basis OS for server-1 and server-2.
However, in the first prototypes, this is not required.

server-1 is the router (openpcc-router).

server-2 is the compute node (ConfidentCompute: compute_boot, router_com, compute_worker) in enclave.

client is planned as an Android/Tizen helper for application writers with openpcc client, but is not included in this version.

Github action scripts are stored at .github/workflows, which will use the resources in server-1, server-2, and client for corresponding actions.

## integration and deployment

Integration (packing or building) step and deployment step are separated.

In github workflows, the two steps should be explicitly separated so that developers can deploy without packging/building and they can also pack/build without deploying. Besides, developers are not allowed to do packing/building and deploying with a single action. Developers should be able to examine test results after packing/building and determine whether to proceed with deployment throughly.

Each component, TAOS-D, client, server-1, and server-2, should be also independently triggered to be built or deployed.

Building: building component Docker images (installable and executable container images).
Packaging: optionally producing Nitro Enclave EIF artifacts from server-2 images.
Deploying: installing an image to a server.

## Version 0.001, the first prototype

Follow the OPENPCC whitepaper: https://github.com/openpcc/openpcc/blob/main/whitepaper/openpcc.pdf

OpenPCC 표준을 기반으로 하여, **프라이버시 중심의 LLM 추론(Prototype 1)**을 위한 **설계 명세서**를 다음과 같이 정의합니다. 이 명세서는 단일 GitHub 리포지토리(`nnstreamer/hybrid`) 내에서의 관리와 AWS 환경으로의 배포를 목표로 합니다.

---

### **[OpenPCC Prototype 1 설계 명세서]**

#### **1. 컴포넌트별 세부 구성**

**A. /client (OpenPCC SDK & CLI)**
*   **역할**: 데이터 암호화 및 증명(Attestation) 검증 [1, 2].
*   **주요 기능**:
    *   **Attestation Verifier**: Router로부터 받은 ComputeNode의 TPM Quote 및 PCR 값을 검증하여 신뢰성을 확인합니다 [2-4].
    *   **HPKE Key Handler**: ComputeNode의 **REK(Request Encryption Key)**를 사용하여 **DEK(Data Encryption Key)**를 암호화합니다 [5-7].
    *   **BHTTP Serializer**: 프롬프트를 **Binary HTTP** 형식으로 인코딩하고 DEK로 암호화합니다 [6, 8].
*   **Prototype 2 대비**: 추후 AuthBank에서 발급받을 'User Badge'를 HTTP 헤더에 담을 수 있는 공간을 설계에 포함합니다 [9, 10].

**B. /server-1 (OpenPCC Router)**
*   **역할**: 클라이언트 요청 중계 및 로드 밸런싱 [11-13].
*   **주요 기능**:
    *   **Node Registry**: 가용한 ComputeNode들의 증명 번들을 캐싱하고 클라이언트에게 전달합니다 [12, 14].
    *   **Stateless Forwarding**: 클라이언트의 암호화된 요청을 내용 복호화 없이 ComputeNode로 전달합니다 [11, 15].
    *   **Anonymization (향후)**: 현재는 직접 중계하지만, 구조적으로 OHTTP Gateway와 연결될 수 있도록 설계합니다 [16, 17].

**C. /server-2 (OpenPCC ComputeNode)**
*   **역할**: **AWS Nitro Enclave** 내 격리된 추론 환경 제공 [18, 19].
*   **주요 기능**:
    *   **Enclave Runtime (Security Layer)**: TPM 2.0과 연동하여 REK를 생성하고, 클라이언트의 DEK를 복호화합니다 [19-21].
    *   **Inference Engine (Compute Layer)**: CPU 기반 경량 모델(예: Llama-3-8B)을 실행합니다 [22, 23].
    *   **Hardening**: **SELinux**를 통한 프로세스 격리, **dm-verity**를 이용한 읽기 전용 파일 시스템, SSH 등 모든 원격 접속 수단 차단을 적용합니다 [24-27].

---

#### **2. 빌드 및 패키징 (Step 1)**

이 단계에서는 각 컴포넌트를 컨테이너화하고, 특히 Server-2를 Nitro Enclave용 이미지로 변환합니다.

*   **Docker 이미지 구성**:
    1.  **`client-image`**: SDK 사용 예제 및 CLI 도구 포함.
    2.  **`router-image`**: Go 기반 Router 바이너리 포함.
    3.  **`compute-enclave-image`**: Ubuntu 22.04 기반, 추론 엔진, 모델 파일 및 OpenPCC 보안 서비스 포함 [28, 29].
*   **Enclave Image File (EIF) 빌드**:
    *   Prototype 1에서는 **Router 주소/Compute 호스트 정보가 배포 시점에 확정**되므로, EIF는 **배포 단계에서 생성**하는 흐름(A 방식)을 기본으로 합니다.
    *   빌드 단계에서는 **compute Docker 이미지까지만 생성**하고, 배포 시점에 `router_com.yaml`에 Router 주소를 고정한 뒤 `nitro-cli build-enclave`로 EIF를 생성합니다.

---

#### **3. AWS 배포 및 CI/CD (Step 2)**

`.github/workflows` 내에 작성할 **GitHub Actions**의 논리적 흐름입니다.

**Workflow 이름: `OpenPCC Proto 1 Deploy`**

1.  **환경 준비**:
    *   AWS 자격 증명 설정 (Secrets 사용).
    *   AWS CLI 및 Nitro CLI 설치.

2.  **Build & Push (Docker)**:
    *   Client, Router, ComputeApp 각각의 Docker 이미지를 빌드합니다.
    *   **Amazon ECR (Elastic Container Registry)**에 이미지를 푸시합니다.

3.  **Enclave Artifact 생성 (Server-2 집중)**:
    *   **배포 단계에서 Compute 호스트가 EIF를 생성**합니다. 이때 Router의 **내부 주소**와 Compute 호스트의 **내부 주소**를 `router_com.yaml`에 고정하여 **Router 등록이 가능한 EIF**를 만듭니다.
    *   생성된 EIF의 **Enclave ID (PCR 값들)**를 추출하여 Router의 구성 파일이나 별도의 Transparency Log에 등록합니다 [31, 32].

4.  **AWS Infrastructure 배포**:
    *   **Terraform** 또는 AWS CLI를 사용하여 다음을 생성/업데이트합니다:
        *   **Router용 EC2**: 일반 인스턴스.
        *   **ComputeNode용 EC2**: **Enclave-enabled** 인스턴스 유형 (예: c5.2xlarge).
    *   ComputeNode 호스트 EC2 내에서 **Router 주소가 고정된 EIF**를 로드하여 Enclave를 실행합니다.

---

#### **4. 설계의 핵심 원칙 (Prototype 1)**

*   **No Privileged Access**: 배포된 ComputeNode 이미지에는 SSH 데몬이 제거되어야 하며, `cloud-init` 등을 통한 런타임 수정을 금지합니다 [24, 27].
*   **Immutable Infrastructure**: ComputeNode는 **배포 시점에 Router 주소를 고정한 EIF**로 실행되며, 런타임 변경(SSH, cloud-init 재설정 등)을 금지합니다. `dm-verity`를 통해 파일 시스템 변조를 방지합니다 [19, 26, 33].
*   **Compatibility**: `/client`와 `/server-1` 사이의 프로토콜에 **User Badge** 헤더 자리를 미리 확보하여, Prototype 2에서 인증 로직 추가 시 통신 규격을 바꿀 필요가 없게 합니다 [9, 10].

이 설계 명세서는 OpenPCC가 강조하는 **"모든 하드웨어 및 소프트웨어 요소가 클라이언트에 의해 증명 가능해야 한다"**는 원칙을 Prototype 1 수준에서 완벽하게 구현하는 데 초점을 맞추고 있습니다 [3, 34, 35].
