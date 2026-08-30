function soma_arcface_metadata_contract_is_valid() {
  local soma_metadata="$1"
  local soma_variant=${2:-current}
  [[ -f "$soma_metadata" ]] || {
    print -u2 -r -- "ArcFace metadata is missing: $soma_metadata"
    return 1
  }
  local soma_contract=(
    '0.generatedClassName|ArcFaceR50'
    '0.method|predict'
    '0.specificationVersion|7'
    '0.inputSchema.0.name|face'
    '0.inputSchema.0.width|112'
    '0.inputSchema.0.height|112'
    '0.outputSchema.0.name|embedding'
    '0.outputSchema.0.shape|[1, 512]'
  )
  case "$soma_variant" in
    current)
      soma_contract+=(
        '0.author|SOMA local conversion of InsightFace w600k_r50.onnx'
        '0.shortDescription|512D ArcFace embedding for aligned 112x112 RGB faces'
        '0.version|1'
      )
      ;;
    legacy)
      soma_contract+=(
        '0.author|SOMA research; converted from InsightFace buffalo_l w600k_r50'
        '0.shortDescription|ArcFace ResNet50 512D face embedding; non-commercial research weight'
        '0.version|insightface-v0.7-w600k-r50-coreml-v1'
      )
      ;;
    *)
      print -u2 -r -- "Unknown ArcFace metadata contract: $soma_variant"
      return 1
      ;;
  esac
  local soma_entry soma_key soma_expected soma_actual
  local soma_valid=1
  for soma_entry in "${soma_contract[@]}"; do
    soma_key=${soma_entry%%|*}
    soma_expected=${soma_entry#*|}
    soma_actual=$(/usr/bin/plutil -extract "$soma_key" raw -o - "$soma_metadata" 2>/dev/null || true)
    if [[ "$soma_actual" != "$soma_expected" ]]; then
      print -u2 -r -- "ArcFace metadata mismatch: $soma_key expected=$soma_expected actual=${soma_actual:-missing}"
      soma_valid=0
    fi
  done
  (( soma_valid == 1 ))
}
