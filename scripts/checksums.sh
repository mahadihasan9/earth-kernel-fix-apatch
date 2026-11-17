#!/usr/bin/env bash
# Regenerate output/SHA256SUMS.txt for every deliverable.
#
# One file only, and every line starts with a self-explanatory path:
#
#   <hash>  main/01-stock-boot.img       stock / rollback
#   <hash>  apatch/02-apatch-boot.img    standard (patch with APatch)
#   <hash>  docker/03-docker-boot.img    Docker variant (patch with APatch)
#   ... plus the matching .zip files and anykernel3/*.zip
#
# Verify everything with:  (cd output && sha256sum -c SHA256SUMS.txt)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/output"
cd "$OUT"

FILES=()
for f in \
	main/01-stock-boot.img main/01-stock-boot.zip \
	apatch/02-apatch-boot.img apatch/02-apatch-boot.zip \
	docker/03-docker-boot.img docker/03-docker-boot.zip
do
	[[ -f "$f" ]] && FILES+=("$f")
done

if [[ -d anykernel3 ]]; then
	while IFS= read -r f; do
		FILES+=("$f")
	done < <(find anykernel3 -maxdepth 1 -type f -name '*.zip' -print | sort)
fi

(( ${#FILES[@]} > 0 )) || { echo "nothing to checksum in $OUT" >&2; exit 1; }

sha256sum "${FILES[@]}" > SHA256SUMS.txt
cat SHA256SUMS.txt
