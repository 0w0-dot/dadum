#!/bin/zsh
# 새 버전을 낸다: 공개해선 안 되는 글이 없는지 보고, 배포 파일을 GitHub 릴리스에 올리고, Homebrew 설치 정보를 고친다.
# 사용: ./release.sh          새 버전을 낸다.
#       ./release.sh --check  올리지 않고 공개 전 점검만 한다.
# 먼저 Resources/Info.plist의 버전을 올리고 커밋해 둔다.
set -euo pipefail
cd "${0:A:h}"
CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

REPO="0w0-dot/dadum"
TAP_DIR="../홈브류-탭"
CASK="$TAP_DIR/Casks/dadum.rb"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
ZIP="dist/Dadum-$VERSION.zip"

if ! $CHECK_ONLY; then
  [[ -z "$(git status --porcelain)" ]] || { echo "커밋하지 않은 변경이 있습니다. 먼저 커밋하세요."; exit 1; }
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "$TAG 는 이미 있습니다. 버전을 올리세요."
    exit 1
  fi
fi

# 공개해선 안 되는 글: API 키 모양, 이 맥의 경로, 이 맥 사용자의 이름과 git 메일.
# 이름과 메일은 이 파일에 적지 않고 실행할 때 이 맥에서 읽는다(이 파일도 공개되기 때문).
# 키 모양과 경로는 이 파일 자신에 걸리지 않게 둘로 나눠 적는다.
PRIVATE=()
for word in "sk-""ant" "/Use""rs/" "$(id -un)" "$(id -F)" "$(git config --global user.email || true)"; do
  [[ -n "$word" ]] && PRIVATE+=("$word")
done

check_private() {
  local where="$1"; shift
  local found=0 hits
  for word in "${PRIVATE[@]}"; do
    hits=$(grep -rlaF -- "$word" "$@" 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
      echo "공개 금지 글이 $where 에 있습니다: $word"
      echo "$hits" | sed 's/^/  /'
      found=1
    fi
  done
  return $found
}

CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
git log --format='%an %ae %cn %ce' > "$CHECK_DIR/authors.txt"
check_private "저장소 파일" $(git ls-files) || { echo "올리지 않고 멈춥니다."; exit 1; }
check_private "커밋 작성자" "$CHECK_DIR/authors.txt" || { echo "올리지 않고 멈춥니다."; exit 1; }

./build.sh --package
mkdir "$CHECK_DIR/app"
ditto -x -k "$ZIP" "$CHECK_DIR/app"
check_private "배포 파일" "$CHECK_DIR/app" || { rm -rf dist; echo "올리지 않고 멈춥니다."; exit 1; }
if $CHECK_ONLY; then
  rm -rf dist
  echo "공개 전 점검 통과: 저장소 파일, 커밋 작성자, 배포 파일"
  exit 0
fi
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

git tag "$TAG"
git push origin HEAD "$TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Dadum $VERSION" \
  --notes "brew install --cask 0w0-dot/tap/dadum"

# Homebrew 설치 정보의 버전과 파일 확인값을 새 것으로 바꾼다.
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git -C "$TAP_DIR" add Casks/dadum.rb
git -C "$TAP_DIR" commit -am "dadum $VERSION"
git -C "$TAP_DIR" push

rm -rf dist
echo "배포 완료: $TAG"
