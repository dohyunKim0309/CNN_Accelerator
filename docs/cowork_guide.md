# CNN Accelerator 프로젝트 협업 가이드

> Git, GitHub, VSCode를 처음 다루는 사람도 따라할 수 있도록 작성된 가이드입니다.
> Python 환경 세팅부터 Merge Request까지 전체 과정을 다룹니다.

---

## 목차

1. [필수 프로그램 설치](#1-필수-프로그램-설치)
2. [Git 초기 설정](#2-git-초기-설정)
3. [VSCode 플러그인 설치](#3-vscode-플러그인-설치)
4. [Python 환경 세팅](#4-python-환경-세팅)
5. [GitHub Repository 가져오기 (Clone)](#5-github-repository-가져오기-clone)
6. [본인 브랜치 만들고 작업하기](#6-본인-브랜치-만들고-작업하기)
7. [Add, Commit, Push 하기](#7-add-commit-push-하기)
8. [Pull Request (Merge Request) 보내기](#8-pull-request-merge-request-보내기)
9. [자주 발생하는 문제와 해결법](#9-자주-발생하는-문제와-해결법)
10. [핵심 명령어 요약](#10-핵심-명령어-요약)

---

## 1. 필수 프로그램 설치

작업을 시작하기 전에 아래 3가지 프로그램이 컴퓨터에 설치되어 있어야 합니다.

### 1.1 Git 설치

Git은 코드 버전 관리 도구입니다.

- **Windows**: <https://git-scm.com/download/win> 접속 → 자동으로 다운로드 시작 → 설치 마법사에서 모두 **Next** 클릭 (기본 설정 권장)
- **macOS**: 터미널을 열고 `git --version` 입력 → 설치 안내 창이 뜨면 **Install** 클릭
- **Linux (Ubuntu)**: 터미널에서 다음 명령어 실행

```bash
sudo apt update
sudo apt install git
```

설치 확인:

```bash
git --version
```

`git version 2.xx.x`처럼 버전이 나오면 성공입니다.

### 1.2 VSCode 설치

VSCode는 코드 편집기입니다.

- 다운로드: <https://code.visualstudio.com/>
- 본인 운영체제에 맞는 버전 다운로드 후 설치 (기본 설정으로 **Next** 진행)

### 1.3 Python 설치

- 다운로드: <https://www.python.org/downloads/>
- **중요**: Windows 설치 시 첫 화면에서 **"Add Python to PATH"** 체크박스를 반드시 체크하세요.

설치 확인:

```bash
python --version
```

또는 (시스템에 따라):

```bash
python3 --version
```

`Python 3.x.x`가 나오면 성공입니다.

---

## 2. Git 초기 설정

처음 한 번만 하면 됩니다. 본인의 이름과 이메일을 등록하는 과정입니다.
이 정보는 commit 기록에 남기 때문에 **GitHub 계정과 동일한 이메일**을 사용하는 것이 좋습니다.

터미널(Windows는 PowerShell, 또는 VSCode 내부 터미널)을 열고 다음을 입력합니다.

```bash
git config --global user.name "본인이름"
git config --global user.email "본인이메일@example.com"
```

확인:

```bash
git config --global --list
```

### 2.1 GitHub 계정 만들기

- <https://github.com/> 접속 → **Sign up** 클릭 → 계정 생성
- 이미 계정이 있다면 로그인만 하면 됩니다.

### 2.2 GitHub 인증 설정 (Personal Access Token)

요즘 GitHub는 비밀번호 대신 **Personal Access Token (PAT)** 으로 인증합니다.

1. GitHub 로그인 → 우측 상단 프로필 → **Settings**
2. 좌측 메뉴 맨 아래 **Developer settings** 클릭
3. **Personal access tokens** → **Tokens (classic)** 클릭
4. **Generate new token (classic)** 클릭
5. 항목 입력:
   - **Note**: `CNN_Accelerator` (이름 아무거나)
   - **Expiration**: 90 days 또는 No expiration
   - **Select scopes**: `repo` 항목 전체 체크
6. 맨 아래 **Generate token** 클릭
7. **생성된 토큰을 반드시 복사해서 메모장에 저장**하세요. 한 번만 보입니다!

> 나중에 push할 때 비밀번호를 물어보면 이 토큰을 붙여넣으면 됩니다.

---

## 3. VSCode 플러그인 설치

VSCode를 실행하고 좌측 사이드바의 **Extensions** 아이콘(네모 4개 모양)을 클릭하거나 단축키 `Ctrl + Shift + X` (Mac: `Cmd + Shift + X`)를 누릅니다.

검색창에 아래 이름을 하나씩 입력하고 **Install** 버튼을 눌러 설치합니다.

| 플러그인 이름 | 설명 | 검색어 |
|---|---|---|
| Markdown All in One | 마크다운 문서를 보기 좋게 렌더링/편집 | `Markdown All in One` |
| GitLens | 누가, 언제, 왜 코드를 작성했는지 표시 | `GitLens` |
| Verilog Formatter | Verilog 코드 자동 정렬 (Vivado보다 우수) | `Verilog Formatter` |
| SystemVerilog | SystemVerilog 문법 지원 | `SystemVerilog` |
| Python | Python 개발 필수 (Microsoft 공식) | `Python` |

> **팁**: 각 플러그인 설치 후 VSCode를 재시작하면 더 안정적으로 작동합니다.

---

## 4. Python 환경 세팅

Python 프로젝트는 가상환경(virtual environment)을 사용하는 것이 좋습니다.
가상환경은 프로젝트마다 독립된 패키지 공간을 만들어줍니다.

### 4.1 가상환경 만들기

작업할 폴더를 정한 뒤 (예: `D:\projects` 또는 `~/projects`), 터미널에서 해당 폴더로 이동합니다.

```bash
# 폴더 이동
cd D:\projects        # Windows
cd ~/projects         # macOS/Linux

# 가상환경 생성 (venv라는 이름의 가상환경 생성)
python -m venv venv
```

### 4.2 가상환경 활성화

```bash
# Windows (PowerShell)
.\venv\Scripts\Activate.ps1

# Windows (CMD)
venv\Scripts\activate.bat

# macOS / Linux
source venv/bin/activate
```

활성화되면 터미널 앞에 `(venv)`가 표시됩니다.

> **PowerShell에서 실행 오류가 난다면** 관리자 권한 PowerShell에서 한 번만 실행:
> ```powershell
> Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
> ```

### 4.3 필요한 패키지 설치

프로젝트에 `requirements.txt`가 있다면:

```bash
pip install -r requirements.txt
```

없다면 필요한 패키지를 하나씩 설치합니다. 예시:

```bash
pip install numpy torch matplotlib
```

### 4.4 VSCode에서 가상환경 선택

1. VSCode에서 Python 파일(`.py`)을 엽니다.
2. 우측 하단 또는 `Ctrl + Shift + P` → **Python: Select Interpreter** 입력
3. 방금 만든 `venv` 안의 Python을 선택합니다.

---

## 5. GitHub Repository 가져오기 (Clone)

이제 GitHub에 있는 코드를 내 컴퓨터로 가져옵니다.

### 5.1 작업 폴더 정하기

먼저 어느 폴더에 프로젝트를 받을지 정합니다. 예시:

```bash
cd D:\projects        # Windows
cd ~/projects         # macOS/Linux
```

### 5.2 Clone 명령 실행

```bash
git clone https://github.com/dohyunKim0309/CNN_Accelerator.git
```

실행하면 `CNN_Accelerator`라는 폴더가 생성되고 그 안에 모든 파일이 다운로드됩니다.

### 5.3 폴더로 이동

```bash
cd CNN_Accelerator
```

### 5.4 VSCode에서 열기

```bash
code .
```

이 명령으로 현재 폴더가 VSCode에서 열립니다. (`code` 명령이 안 되면 VSCode를 직접 실행하고 **File → Open Folder**로 폴더 선택)

---

## 6. 본인 브랜치 만들고 작업하기

### 브랜치(branch)란?

브랜치는 **나만의 작업 공간**입니다. 메인 코드(main 브랜치)를 건드리지 않고 따로 떨어진 공간에서 작업한 뒤, 나중에 합치는 방식입니다. 여러 명이 동시에 작업해도 충돌이 적게 일어납니다.

### 6.1 현재 브랜치 확인

```bash
git branch
```

`* main`이 보일 것입니다. (`*` 표시가 현재 위치한 브랜치)

### 6.2 최신 코드 가져오기 (작업 시작 전 항상!)

```bash
git pull origin main
```

### 6.3 새 브랜치 만들고 이동하기

브랜치 이름은 **자기 이름이나 작업 내용**으로 짓는 것이 좋습니다.

```bash
git checkout -b feature/본인이름
```

예시:

```bash
git checkout -b feature/dohyun
git checkout -b fix/conv-layer-bug
git checkout -b dev/jiwoo
```

이제 본인만의 브랜치에서 작업을 시작할 수 있습니다.

브랜치 확인:

```bash
git branch
```

`* feature/본인이름`처럼 새 브랜치에 `*` 표시가 있으면 성공입니다.

---

## 7. Add, Commit, Push 하기

코드 작업이 끝났다면 GitHub에 업로드해야 합니다. 3단계로 이루어집니다.

```
[수정한 파일] --add--> [Staging Area] --commit--> [Local Repository] --push--> [GitHub]
```

### 7.1 변경사항 확인

```bash
git status
```

- **빨간색 파일**: 아직 add 안 된 변경 파일
- **초록색 파일**: add 완료된 파일

### 7.2 Add (스테이징)

수정한 파일을 commit 대상으로 등록합니다.

```bash
# 특정 파일만 add
git add filename.py

# 모든 변경 파일 add
git add .
```

### 7.3 Commit (확정)

변경사항을 메시지와 함께 저장합니다.

```bash
git commit -m "작업 내용 설명"
```

좋은 commit 메시지 예시:

```bash
git commit -m "Add convolution layer module"
git commit -m "Fix pooling stride calculation bug"
git commit -m "Update README with installation guide"
```

> **팁**: commit 메시지는 무엇을 했는지 짧고 명확하게 작성하세요.

### 7.4 Push (업로드)

처음 push할 때는 브랜치 이름을 명시합니다.

```bash
git push -u origin feature/본인이름
```

`-u origin feature/본인이름`은 처음 한 번만 입력하면 되고, 그 후로는:

```bash
git push
```

만 입력하면 됩니다.

> push 시 GitHub 계정과 **Personal Access Token**을 물어볼 수 있습니다.
> 사용자명에는 GitHub ID, 비밀번호 자리에는 앞서 발급받은 토큰을 붙여넣으세요.

---

## 8. Pull Request (Merge Request) 보내기

> GitHub에서는 **Pull Request (PR)**, GitLab에서는 **Merge Request (MR)** 이라고 부릅니다. 같은 개념입니다.

내 브랜치의 작업을 main 브랜치에 합치자고 요청하는 과정입니다.

### 8.1 GitHub 웹페이지에서 PR 만들기

1. 브라우저에서 <https://github.com/dohyunKim0309/CNN_Accelerator> 접속
2. push 직후라면 노란 띠로 **"Compare & pull request"** 버튼이 보일 것입니다. 클릭.
3. 안 보이면 상단 **Pull requests** 탭 → **New pull request** 클릭

### 8.2 브랜치 설정

- **base**: `main` (합쳐질 대상 브랜치)
- **compare**: `feature/본인이름` (내 작업 브랜치)

### 8.3 PR 작성

- **Title**: 어떤 작업인지 한 줄 요약 (예: `Add convolution layer implementation`)
- **Description**: 무엇을, 왜 변경했는지 설명. 예시:

````
## 작업 내용
- Conv2D 레이어 클래스 추가
- 입력 채널/출력 채널 파라미터 처리

## 테스트
- 3x3 커널 단위 테스트 통과

## 비고
- @리뷰어이름 리뷰 부탁드립니다
````

### 8.4 Create pull request 클릭

PR이 생성됩니다. 이제 팀원이 코드를 검토(review)하고, OK 사인이 나면 **Merge pull request** 버튼으로 main에 합쳐집니다.

### 8.5 PR이 merge된 후

내 로컬 브랜치를 main과 동기화합니다.

```bash
# main으로 이동
git checkout main

# 최신 코드 가져오기
git pull origin main

# 다 끝난 브랜치는 삭제해도 됩니다 (선택)
git branch -d feature/본인이름
```

---

## 9. 자주 발생하는 문제와 해결법

### Q1. `git push` 시 인증 실패

→ Personal Access Token이 만료되었거나 잘못 입력한 경우입니다. 2.2를 참고해 토큰을 다시 발급받으세요.

### Q2. `git pull` 시 conflict (충돌) 발생

→ 여러 사람이 같은 파일을 수정한 경우입니다. 충돌난 파일을 VSCode로 열면 다음과 같이 표시됩니다.

```
<<<<<<< HEAD
내가 작성한 내용
=======
다른 사람이 작성한 내용
>>>>>>> main
```

이 부분을 직접 수정해서 원하는 형태로 고친 뒤 `<<<<<<<`, `=======`, `>>>>>>>` 줄을 모두 지우고, 다시 add/commit/push 하면 됩니다.

VSCode에서는 GitLens/내장 Git 기능이 **"Accept Current Change"**, **"Accept Incoming Change"**, **"Accept Both Changes"** 버튼을 제공해서 클릭 한 번으로 해결할 수 있습니다.

### Q3. 잘못 add 했을 때

```bash
git reset HEAD filename
```

### Q4. 마지막 commit 메시지 수정

```bash
git commit --amend -m "새로운 메시지"
```

> 단, 이미 push한 commit은 수정하지 않는 게 좋습니다.

### Q5. 변경사항 전부 취소하고 싶을 때 (위험!)

```bash
git checkout -- .
```

→ 아직 add하지 않은 변경사항이 모두 사라집니다.

### Q6. 다른 브랜치로 이동하려는데 안 됨

→ 현재 브랜치에서 변경사항을 commit하거나 stash해야 합니다.

```bash
git stash         # 잠시 저장
git checkout main # 다른 브랜치로 이동
git stash pop     # 다시 돌아와서 꺼내기
```

---

## 10. 핵심 명령어 요약

### 일상적인 작업 흐름

```bash
# 1. 작업 시작 전 - 최신 코드 받기
git checkout main
git pull origin main

# 2. 본인 브랜치로 이동 (또는 새로 생성)
git checkout feature/본인이름
# 또는 새 브랜치: git checkout -b feature/새기능

# 3. 코드 작업

# 4. 변경사항 확인
git status

# 5. add, commit, push
git add .
git commit -m "작업 내용"
git push
```

### 자주 쓰는 명령어 치트시트

| 명령어 | 설명 |
|---|---|
| `git clone <URL>` | Repository를 로컬로 복제 |
| `git status` | 현재 상태 확인 |
| `git branch` | 브랜치 목록 보기 |
| `git checkout -b <이름>` | 새 브랜치 만들고 이동 |
| `git checkout <이름>` | 기존 브랜치로 이동 |
| `git pull origin main` | 원격 main 브랜치 최신화 |
| `git add .` | 모든 변경 파일 스테이징 |
| `git commit -m "메시지"` | 변경사항 확정 |
| `git push` | 원격 저장소에 업로드 |
| `git log --oneline` | commit 이력 한 줄로 보기 |
| `git diff` | 변경 내용 비교 |

---

## 마무리

처음에는 명령어가 익숙하지 않아 헷갈릴 수 있지만, 며칠만 반복하면 자연스럽게 손이 갑니다.
모르는 게 있으면 `git help <명령어>` 또는 팀원에게 편하게 물어보세요.

**Happy Coding!**