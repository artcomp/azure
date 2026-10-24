set -euo pipefail

app_name="$(echo "$APP_NAME_RAW" | tr '[:upper:]' '[:lower:]')"
if ! [[ "$app_name" =~ ^[a-z0-9][a-z0-9-]{1,40}$ ]]; then
  echo "::error::app_name invalido: '$APP_NAME_RAW'. Use apenas a-z, 0-9 e hifens (2-41 chars)."
  exit 1
fi

case "$ENVIRONMENT" in
  dev|homolog|prod) ;;
  *) echo "::error::environment invalido: $ENVIRONMENT"; exit 1 ;;
esac
case "$REGION" in
  eastus|eastus2|brazilsouth) ;;
  *) echo "::error::region invalida: $REGION"; exit 1 ;;
esac

rg_name="${ENVIRONMENT}-rg-${app_name}"
appi_prefix="${ENVIRONMENT}-appi-${app_name}-${REGION}-"
log_prefix="${ENVIRONMENT}-log-${app_name}-${REGION}-"

max=0
if [ "$(az group exists --name "$rg_name")" = "true" ]; then
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if [[ "$name" =~ ^${appi_prefix}([0-9]{3})$ ]] || [[ "$name" =~ ^${log_prefix}([0-9]{3})$ ]]; then
      n=$((10#${BASH_REMATCH[1]}))
      [ "$n" -gt "$max" ] && max=$n
    fi
  done < <(az resource list --resource-group "$rg_name" --query "[].name" --output tsv 2>/dev/null || true)
fi

next=$((max + 1))
if [ "$next" -gt 999 ]; then
  echo "::error::Contador estourou 999 para os prefixos '$appi_prefix' / '$log_prefix'. Renomeie/limpe recursos antigos."
  exit 1
fi

appi_name="$(printf '%s%03d' "$appi_prefix" "$next")"
log_name="$(printf '%s%03d' "$log_prefix" "$next")"

{
  echo "rg_name=$rg_name"
  echo "appi_name=$appi_name"
  echo "log_name=$log_name"
} >> "$GITHUB_OUTPUT"

echo "NNN=$(printf '%03d' "$next") (max atual: $max)"
echo "  Resource Group: $rg_name"
echo "  Log Analytics:  $log_name"
echo "  App Insights:   $appi_name"
