# server-1 (Router + oHTTP Gateway)

OpenPCC v0.002의 `server-1`은 Router와 oHTTP Gateway를 동일 인스턴스에서 실행한다.

## 구성 요소

- `mem-router` (포트 3600): compute 노드 선택 및 forwarding.
- `mem-gateway` (포트 3200): oHTTP 디캡슐화 후 allow-list된 내부 라우팅.
- `mem-credithole` (포트 3501): upstream 구성 요소(credit/bank 흐름은 v0.002 범위 밖).

## 동작

- `entrypoint.sh`는 `mem-credithole → mem-gateway → mem-router` 순서로 실행한다.
- `mem-credithole`과 `mem-gateway`는 백그라운드, `mem-router`는 포그라운드로 유지된다.

## 참고

- credit/bank 플로우는 v0.002 범위 밖이므로 기본 포트/설정은 upstream 값을 유지한다.
