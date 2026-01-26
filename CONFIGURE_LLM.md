# CONFIGURE LLM (초보자용)

이 문서는 **LLM 모델 교체** 또는 **LLM 런타임 교체**를 위해 필요한 작업을
step-by-step으로 설명합니다. 현재 코드/PR에 포함된 설정만 사용합니다.

---

## 핵심 요약 (Q1~Q4 반영)

- **Q1**: LLM 모델 파일은 코드에 포함되어 있지 않습니다. 모델 이름만 설정에 존재합니다.
- **Q2**: 새 모델을 쓰려면 설정의 **모델 이름**과 **런타임 주소**를 바꾸고, 런타임에 모델을 준비해야 합니다.
- **Q3**: `router_com.yaml`에도 모델 이름이 들어가는 이유는 **라우터 등록/태그 기반 라우팅**과 **워커 모델 목록** 때문입니다.
- **Q4**: Compute node에 모델을 넣으려면 **런타임이 실제 모델을 보유**해야 하며,
  설정에서 모델 이름을 일치시키고 런타임을 가리키도록 해야 합니다.

---

## Step 1) 현재 구조 이해하기

### 1-1. 기본 LLM 런타임

기본값은 **Ollama**입니다. `compute_boot.yaml`의 `inference_engine.type` 기본값이 `ollama`로 설정되어 있습니다.【F:server-2/config/compute_boot.yaml†L1-L13】

### 1-2. 모델은 빌드 단계에서 이미지에 포함됨

모델 이름은 설정에 존재하며, **compute 이미지 빌드 단계에서 Ollama가 모델을 pull**해 이미지에 포함합니다.  
소스 코드에는 모델 파일을 직접 포함하지 않습니다.【F:server-2/Dockerfile†L1-L80】【F:server-2/config/compute_boot.yaml†L1-L13】【F:server-2/config/router_com.yaml†L6-L27】

### 1-3. 런타임 주소

런타임 주소는 두 곳에 설정됩니다:

- `compute_boot.yaml`: `INFERENCE_ENGINE_URL`
- `router_com.yaml`: `LLM_BASE_URL`

기본값은 `http://localhost:11434`입니다.【F:server-2/config/compute_boot.yaml†L1-L13】【F:server-2/config/router_com.yaml†L16-L19】

---

## Step 2) LLM 모델 교체하기 (모델 이름 변경)

### 2-1. compute_boot 설정 변경

`INFERENCE_ENGINE_MODEL_1` 값을 새 모델 이름으로 설정합니다.

예: `llama3.2:1b` → `qwen2:1.5b-instruct`【F:server-2/config/compute_boot.yaml†L1-L13】

### 2-2. router_com 설정도 동일하게 변경

`MODEL_1` 값을 **위와 동일한 모델 이름**으로 설정합니다.【F:server-2/config/router_com.yaml†L6-L27】

### 2-3. 모델이 런타임에 실제로 존재해야 함

이 구성은 **엔클레이브 실행 중에는 모델을 다운로드하지 않습니다.**  
대신 Docker build 단계에서 Ollama가 모델을 pull해 이미지에 포함해야 합니다.【F:server-2/Dockerfile†L1-L80】

> 모델을 바꾸면 Docker build 단계의 `OLLAMA_MODEL`(또는 동등한 build arg)도 함께 변경해야 합니다.

---

## Step 3) LLM 런타임 교체하기

### 3-1. 런타임 타입 변경

`INFERENCE_ENGINE_TYPE`을 새 런타임 타입으로 설정합니다.【F:server-2/config/compute_boot.yaml†L1-L13】

### 3-2. 런타임 주소 변경

`INFERENCE_ENGINE_URL`과 `LLM_BASE_URL`을 새 런타임 주소로 설정합니다.【F:server-2/config/compute_boot.yaml†L1-L13】【F:server-2/config/router_com.yaml†L16-L19】

### 3-3. 런타임이 모델을 보유하고 있는지 확인

현재 구성은 **런타임이 모델을 직접 가지고 있다는 전제**입니다.  
즉, 새 런타임에도 동일한 모델이 있어야 요청이 정상 처리됩니다.【F:server-2/config/compute_boot.yaml†L1-L13】【F:server-2/config/router_com.yaml†L16-L19】

---

## Step 4) 왜 `router_com.yaml`에도 모델 이름이 필요할까?

`router_com.yaml`에는 다음 정보가 있습니다:

- `models`: 워커가 처리 가능한 모델 목록  
- `router_agent.tags`: 라우터에 등록하는 모델 태그  

이 값들이 라우팅/등록에 사용되므로, **compute_boot에서 설정한 모델 이름과 항상 일치**해야 합니다.【F:server-2/config/router_com.yaml†L6-L27】

---

## Step 5) 최소 변경 체크리스트

모델 또는 런타임을 바꿀 때 아래 4가지만 확인하면 됩니다:

1. `INFERENCE_ENGINE_MODEL_1` (compute_boot)  
2. `MODEL_1` (router_com)  
3. `INFERENCE_ENGINE_URL` (compute_boot)  
4. `LLM_BASE_URL` (router_com)

그리고 **LLM 런타임이 해당 모델을 실제로 보유하고 있어야** 합니다.【F:server-2/config/compute_boot.yaml†L1-L13】【F:server-2/config/router_com.yaml†L6-L19】

---

## 부록: 기본 설정 한눈에 보기

- 런타임 타입: `ollama`  
- 모델 기본값: `llama3.2:1b`  
- 런타임 주소: `http://localhost:11434`  

위 기본값들은 모두 설정 파일에서 확인할 수 있습니다.【F:server-2/config/compute_boot.yaml†L1-L13】【F:server-2/config/router_com.yaml†L6-L19】

---

## FAQ

**Q1. 현 코드와 Pull request에 LLM serving을 위해 포함된 LLM model이 있는가?**  
A. 모델 파일은 소스 코드에 직접 포함되지 않습니다. 대신 compute 이미지 빌드 단계에서 Ollama가 모델을 pull해 이미지에 포함합니다.【F:server-2/Dockerfile†L1-L80】

**Q2. LLM model을 새로 가져오기 위해서는 어떠한 작업을 해주면 되는가?**  
A. Docker build 단계에서 새 모델을 pull하도록 `OLLAMA_MODEL`(또는 build arg)을 변경하고, `INFERENCE_ENGINE_MODEL_1`과 `MODEL_1`을 동일한 이름으로 맞춘 뒤 `LLM_BASE_URL`이 올바른 런타임을 가리키도록 설정합니다.【F:server-2/Dockerfile†L1-L80】【F:server-2/config/compute_boot.yaml†L1-L13】【F:server-2/config/router_com.yaml†L6-L19】

**Q3. router_com.yaml 에도 모델 이름 정보가 들어가는 이유는?**  
A. 라우터 등록/태그 기반 라우팅과 워커가 처리 가능한 모델 목록을 설정하기 위해서입니다.【F:server-2/config/router_com.yaml†L6-L27】

**Q4. 사용할 LLM model을 compute node에 넣기 위해 필요한 작업은?**  
A. Docker build 단계에서 모델이 포함되도록 준비하고(사전 pull), 설정에서 모델 이름과 런타임 주소를 일치시키면 됩니다.【F:server-2/Dockerfile†L1-L80】【F:server-2/config/compute_boot.yaml†L1-L13】【F:server-2/config/router_com.yaml†L6-L19】
