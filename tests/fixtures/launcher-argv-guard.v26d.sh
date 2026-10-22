# CI-FIXTURE-ONLY copy of the bound omp launcher's argv-scan block (lines args=("$@") .. done).
# Provenance: installed release 2026-10-22-ownerdispatch-v26d/omp, launcher file sha256 dd8fa3ba90cb8c55c7b77f2a66227bc1009cb1789a22f86e955d9ac746a46c20,
# extracted with: awk '/^args=\("\$@"\)$/,/^done$/'. Block sha256 (body below this header) fe11df1da5b9daae025256c10b12bc68ab2b1a2c41b89d889e3ba1ac3eacabbd.
# NOT runtime proof: the Mac's installed wrapper is checked separately (installed mode).
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  arg=${args[$i]}
  case "$arg" in
    --config)
      ((i+1 < ${#args[@]})) || die "--config missing value"
      case "${args[$((i+1))]}" in
        "$overlay"|"$offline_overlay") ;;
        *) die "only the bound Herdr worker overlays are allowed" ;;
      esac
      ((i++)) ;;
    --profile|--profile=*|--no-extensions|-e|-e?*|--extension|--extension=*|--config=*|--hook|--hook=*|--plugin-dir|--plugin-dir=*|--plugin-url|--plugin-url=*)
      die "argument may bypass the bound extension: $arg" ;;
  esac
done
