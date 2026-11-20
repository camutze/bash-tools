#!/usr/bin/env bash
# ==============================================================================
# Script: converter.sh
# Objetivo: Conversão em massa de imagens para JPG (70% da resolução original)
#           preservando a estrutura de subpastas a partir do diretório atual.
# ==============================================================================

set -u

# ------------------------------------------------------------------------------
# 1. Configuração das pastas (relativas à pasta atual de execução)
# ------------------------------------------------------------------------------
PASTA_ATUAL="$(pwd)"
ORIGEM_RELATIVA="fotos"
DESTINO_RELATIVO="Fotos_convertidas"

PASTA_ORIGEM="${PASTA_ATUAL}/${ORIGEM_RELATIVA}"
PASTA_DESTINO="${PASTA_ATUAL}/${DESTINO_RELATIVO}"

# Percentual de redimensionamento (70% da largura e altura originais)
ESCALA="70%"

# Qualidade JPEG de saída (ajuste entre 1 e 100 se desejar)
QUALIDADE_JPG="90"

# ------------------------------------------------------------------------------
# 2. Verificações iniciais de segurança e dependências
# ------------------------------------------------------------------------------
if ! command -v magick >/dev/null 2>&1; then
    echo "Erro: O comando 'magick' (ImageMagick) não foi encontrado." >&2
    echo "Instale com: sudo apt update && sudo apt install -y imagemagick libheif1" >&2
    exit 1
fi

if [ ! -d "$PASTA_ORIGEM" ]; then
    echo "Erro: A pasta de origem '$PASTA_ORIGEM' não existe." >&2
    exit 1
fi

# Garante que a pasta de destino exista
mkdir -p "$PASTA_DESTINO"

# ------------------------------------------------------------------------------
# 3. Identificação do usuário real (mesmo se rodado com sudo por engano)
# ------------------------------------------------------------------------------
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    USUARIO_ALVO="$SUDO_USER"
else
    USUARIO_ALVO="$(id -un)"
fi
GRUPO_ALVO="$(id -gn "$USUARIO_ALVO" 2>/dev/null || id -gn)"

# ------------------------------------------------------------------------------
# 4. Percorrer a pasta de origem e subpastas com segurança
# ------------------------------------------------------------------------------
# Lista de extensões comuns + formatos adicionais suportados pelo ImageMagick.
# A validação real de "é imagem?" também ocorre com `magick identify` para
# cobrir formatos suportados pelo ImageMagick mesmo sem extensão óbvia.
EXTENSOES_REGEX='\.\(heic\|heif\|jpg\|jpeg\|png\|webp\|bmp\|tif\|tiff\|gif\|avif\|jp2\|j2k\|pcx\|tga\|ppm\|pgm\|pbm\|psd\|xcf\|svg\|ico\|cur\|dds\|exr\|hdr\)$'

# Evita entrar na própria pasta de destino caso ela esteja dentro da origem
ORIGEM_REAL="$(realpath "$PASTA_ORIGEM")"
DESTINO_REAL="$(realpath "$PASTA_DESTINO")"

FIND_ARGS=("$ORIGEM_REAL")
if [[ "$DESTINO_REAL" == "$ORIGEM_REAL"/* ]]; then
    FIND_ARGS+=(-path "$DESTINO_REAL" -prune -o)
fi
FIND_ARGS+=(-type f -print0)

CONTADOR_CONVERTIDOS=0
CONTADOR_IGNORADOS=0
CONTADOR_ERROS=0

echo "Origem : $ORIGEM_REAL"
echo "Destino: $DESTINO_REAL"
echo "Escala : $ESCALA -> JPG (qualidade ${QUALIDADE_JPG}%)"
echo "------------------------------------------------------------------------------"

while IFS= read -r -d '' ARQUIVO_ORIGEM; do
    # Caminho relativo a partir da pasta de origem (ex: "Viagem/imagem.heic")
    CAMINHO_RELATIVO="${ARQUIVO_ORIGEM#"$ORIGEM_REAL"/}"

    # Verifica se a extensão bate com a lista conhecida OU se o ImageMagick
    # reconhece o arquivo como imagem válida (cobre outros formatos do ImageMagick).
    EXTENSAO_BAIXA="${ARQUIVO_ORIGEM##*.}"
    EXTENSAO_BAIXA="${EXTENSAO_BAIXA,,}"

    MATCH_EXTENSAO=0
    if [[ "$ARQUIVO_ORIGEM" =~ $EXTENSOES_REGEX ]]; then
        MATCH_EXTENSAO=1
    fi

    # Verifica com o ImageMagick se é uma imagem legível (evita tentar converter
    # arquivos de texto, PDFs indesejados, scripts, logs, etc., salvo se for imagem)
    if [ "$MATCH_EXTENSAO" -eq 0 ]; then
        if ! magick identify -ping "$ARQUIVO_ORIGEM" >/dev/null 2>&1; then
            echo "[IGNORADO - não é imagem] $CAMINHO_RELATIVO"
            CONTADOR_IGNORADOS=$((CONTADOR_IGNORADOS + 1))
            continue
        fi
    else
        if ! magick identify -ping "$ARQUIVO_ORIGEM" >/dev/null 2>&1; then
            echo "[IGNORADO - arquivo inválido/corrompido] $CAMINHO_RELATIVO"
            CONTADOR_IGNORADOS=$((CONTADOR_IGNORADOS + 1))
            continue
        fi
    fi

    # Monta o caminho de destino trocando a extensão final por .jpg
    RELATIVO_SEM_EXT="${CAMINHO_RELATIVO%.*}"
    # Caso o arquivo não tenha ponto no nome, mantém o nome inteiro
    if [ "$RELATIVO_SEM_EXT" = "$CAMINHO_RELATIVO" ]; then
        ARQUIVO_DESTINO="${DESTINO_REAL}/${CAMINHO_RELATIVO}.jpg"
    else
        ARQUIVO_DESTINO="${DESTINO_REAL}/${RELATIVO_SEM_EXT}.jpg"
    fi

    PASTA_DESTINO_ATUAL="$(dirname "$ARQUIVO_DESTINO")"

    # Cria automaticamente todas as subpastas necessárias no destino
    mkdir -p "$PASTA_DESTINO_ATUAL"

    echo "[CONVERTENDO] $CAMINHO_RELATIVO  -->  ${ARQUIVO_DESTINO#"$DESTINO_REAL"/}"

    # Para formatos multi-quadro (como GIF/TIFF), `[0]` seleciona o primeiro
    # quadro para gerar um JPG limpo; `-auto-orient` respeita a orientação EXIF
    # (muito comum em fotos de celular / HEIC / JPG) antes de redimensionar.
    if magick "${ARQUIVO_ORIGEM}[0]" \
        -auto-orient \
        -resize "$ESCALA" \
        -strip \
        -quality "$QUALIDADE_JPG" \
        "$ARQUIVO_DESTINO"
    then
        CONTADOR_CONVERTIDOS=$((CONTADOR_CONVERTIDOS + 1))
    else
        echo "[ERRO] Falha ao converter: $CAMINHO_RELATIVO" >&2
        CONTADOR_ERROS=$((CONTADOR_ERROS + 1))
    fi

done < <(find "${FIND_ARGS[@]}")

echo "------------------------------------------------------------------------------"
echo "Conversão concluída."
echo "Convertidos: $CONTADOR_CONVERTIDOS | Ignorados: $CONTADOR_IGNORADOS | Erros: $CONTADOR_ERROS"

# ------------------------------------------------------------------------------
# 5. Correção de propriedade e permissões na pasta de destino
# ------------------------------------------------------------------------------
# Se o script (ou uma execução anterior) deixou arquivos pertencentes ao root,
# ajusta a propriedade para o usuário atual quando possível.
# Nota: rodar `chown` sem sudo só funciona se o usuário já for dono dos arquivos;
# se algum arquivo pertencer ao root e o script estiver rodando sem sudo, o
# `chown` pode emitir aviso de permissão negada — o script não trava por causa disso.
echo "Ajustando proprietário (${USUARIO_ALVO}:${GRUPO_ALVO}) e permissões em '$DESTINO_REAL'..."

if [ "$(id -u)" -eq 0 ]; then
    chown -R "${USUARIO_ALVO}:${GRUPO_ALVO}" "$DESTINO_REAL"
else
    # Tenta corrigir caso o usuário atual seja dono (ou se houver permissão)
    chown -R "${USUARIO_ALVO}:${GRUPO_ALVO}" "$DESTINO_REAL" 2>/dev/null || true
fi

# Pastas com permissão 755 (rwxr-xr-x) e arquivos com permissão 644 (rw-r--r--)
find "$DESTINO_REAL" -type d -exec chmod 755 {} +
find "$DESTINO_REAL" -type f -exec chmod 644 {} +

# Se houver algum arquivo que ainda pertença ao root de uma execução antiga com sudo,
# avisa claramente como corrigir sem exigir rodar o script inteiro como root.
if find "$DESTINO_REAL" -user root -print -quit 2>/dev/null | grep -q .; then
    echo "Aviso: Há arquivos em '$DESTINO_REAL' pertencentes ao 'root' de execuções anteriores com sudo." >&2
    echo "Para corrigir a propriedade sem rodar o script inteiro com sudo, execute:" >&2
    echo "  sudo chown -R \"${USUARIO_ALVO}:${GRUPO_ALVO}\" \"$DESTINO_REAL\"" >&2
fi

echo "Concluído com sucesso!"
